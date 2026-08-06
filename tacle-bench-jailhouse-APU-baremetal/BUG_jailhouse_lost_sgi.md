# The ZCU104 lockup: Jailhouse silently drops guest IPIs

How a TACLeBench interference campaign spent a week dying every few minutes, what
was actually wrong, and what fixed it.

Board: ZCU104 (ZynqMP, 4× Cortex-A53, GIC-400 = **GICv2**), Linux 6.1.70
(`xlnx_rebase_v6.1_LTS`), Jailhouse (Omnivisor fork). Investigated 2026-08-04 → 06.

---

## TL;DR

We ran benchmarks bare-metal in a Jailhouse cell on CPU 3 while stress-ng loaded
CPUs 0–2. Every few minutes the whole board froze.

**What was really happening:** Linux wakes a sleeping task on another CPU by
putting it on that CPU's to-do list and then poking it with an interrupt (an
"IPI"). Jailhouse sits between Linux and the interrupt controller. It has a bug:
when it sees an incoming IPI whose number matches one already in flight, it
assumes it's a duplicate and **throws it away** — but it only compares the
*number*, not *who sent it*. Two different CPUs sending "IPI 1" look identical to
it, so the second one vanishes.

When that lost IPI was the one waking Linux's RCU housekeeping thread, that thread
stayed asleep forever, holding up the kernel until everything ground to a halt.

**Why it took a week:** every symptom pointed at CPU starvation — "the stressors
are hogging the CPUs, RCU can't run". So we tried every priority knob there is
(`nice`, `chrt`, RT priorities, changing the kernel's preemption model). None
worked, because nothing was starving. The task wasn't waiting for CPU time; it was
waiting for a wake-up call that had been thrown in the bin.

**Two fixes, both working:**

1. *Linux side (workaround, in use now):* `echo NO_TTWU_QUEUE > /sys/kernel/debug/sched/features`
   tells Linux to stop using the IPI-based wake-up path. No IPI, nothing to lose.
   Took the failing configuration from "dead in 2 minutes" to a **6-hour clean run,
   all 6 configurations × 52 benchmarks, zero stalls**.
2. *Jailhouse side (real fix, two parts):* make the sender part of an SGI's
   identity so IPIs from different CPUs stop being mistaken for each other, and
   re-arm rather than discard when the matching interrupt is merely *active*.
   With both, the previously-fatal configuration runs with **zero dropped SGIs and
   zero stalls, and no Linux workaround at all**.

**The one-line diagnosis**, if you ever see it again:

```
rcu: rcu_preempt kthread ... ->state=0x200 ->cpu=N
```

`0x200` is `TASK_WAKING`. If a task sits in `TASK_WAKING` for *seconds*, no amount
of priority tuning will help you — a wakeup has been lost, and you should be
looking at whatever sits between the kernel and the interrupt controller.

---

## 1. The symptom

Minutes into a run the board stopped responding: no panic, no oops, ssh dead,
sometimes still answering ping. The console showed:

```
rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
rcu:   All QSes seen, last rcu_preempt kthread activity 21012, ... root ->qsmask 0x0
rcu:   rcu_preempt kthread timer wakeup didn't happen for 21019 jiffies! ... ->state=0x200
rcu:   Possible timer handling issue on cpu=2
rcu:   rcu_preempt kthread starved for 21042 jiffies! ... ->state=0x200 ->cpu=2
```

It required all three of: the hypervisor **and** a running inmate cell **and** a
saturating stressor. Any two of the three ran indefinitely.

## 2. The false trail (and why it was so convincing)

`rcu_preempt kthread starved for 21042 jiffies` reads as *"the stressors are
eating all the CPU and RCU can't get scheduled"*. That framing drove a week of
work, all of it useless:

| attempted | result |
|---|---|
| `nice -n 19` on the stressors | no effect |
| `chrt -f -p 1` on the RCU kthread | no effect |
| `rcutree.kthread_prio=1` | no effect |
| Reusing the cell (1612 CPU hotplugs → 1) | no effect |
| Pausing stressors around cell operations | helped slightly (6/52 → 10/52) |
| Fewer workers (8 → 4) | helped slightly |
| Rebuilding the kernel `PREEMPT_NONE` → `PREEMPT`, `HZ` 250 → 1000 | **no effect** |

The kernel rebuild was the decisive negative result: a fully preemptible kernel
changed nothing. That killed the starvation theory.

**Two things in the trace had been saying so all along:**

- **`All QSes seen ... root ->qsmask 0x0`** — every CPU had *already* reported its
  RCU quiescent state. Nothing was blocking the grace period. It was waiting only
  for the GP kthread itself to wake up.
- **`->state=0x200` is `TASK_WAKING`**, not `TASK_RUNNING`. The kthread was not
  runnable-but-unscheduled. It was stuck *mid-wakeup*.

And the CPU it was assigned to was demonstrably healthy — it answered a backtrace
IPI, with a stack showing it taking interrupts and running the scheduler normally:

```
Task dump for CPU 2:
task:stress-ng-cpu   state:R  running task
Call trace:
 __schedule+0x30c/0x700
 do_notify_resume+0xe0/0x1200
 el0_interrupt+0x104/0x190
 el0t_64_irq+0x190/0x194
```

A live CPU, servicing interrupts, running the scheduler — next to a nice-0 kernel
thread it never picked up. That is not starvation. That is a lost wakeup.

## 3. What `TASK_WAKING` actually means

Linux has two ways to wake a task on another CPU:

- **Direct:** take the target runqueue's lock and enqueue the task.
- **Remote (`TTWU_QUEUE`, the default):** push the task onto the target CPU's
  `wake_list` and send it an IPI. The target drains the list when it takes the
  IPI. Cheaper — it avoids bouncing the runqueue lock between CPUs.

`TASK_WAKING` is the state a task holds **in the window between being put on that
`wake_list` and the target draining it.**

```
ttwu_queue_wakelist()
  └─ __ttwu_queue_wakelist()
       ├─ llist_add(&p->wake_entry, &rq->wake_list)   ← task now TASK_WAKING
       └─ __smp_call_single_queue(cpu)
            └─ send_call_function_single_ipi(cpu)
                 └─ arch_send_call_function_single_ipi(cpu)   ← SGI 1 on arm64
```

So a task stuck in `TASK_WAKING` for 84–336 seconds means exactly one thing: **the
IPI was never delivered.** The task is on a list nobody was told to read.

On arm64 that IPI is **SGI 1 = `IPI_CALL_FUNC`**. Remember that number.

## 4. Where the IPI went

Under Jailhouse the root cell does not touch the GIC directly. A guest write to
`GICD_SGIR` traps to the hypervisor:

```
Linux: arch_send_call_function_single_ipi()  →  write GICD_SGIR
   ↓ trap
Jailhouse: gic_handle_sgir_write()  →  irqchip_set_pending(target_cpu, sgi_id)
   ↓
           gicv2_inject_irq()  →  writes a GICv2 list register (LR)
```

GICv2 virtualisation delivers interrupts to a guest through **list registers**.
GIC-400 has only **4** of them, so Jailhouse keeps a 256-entry per-CPU software
ring for the overflow.

### First hypothesis: the ring overflows — WRONG

`irqchip_set_pending()` has no `else`:

```c
new_tail = (pending->tail + 1) % MAX_PENDING_IRQS;
if (new_tail != pending->head) {
        pending->irqs[pending->tail] = irq_id;
        ...
        pending->tail = new_tail;
}
/* ring full → interrupt silently discarded, no counter, no warning */
```

That *is* a real latent defect, and it looked like the answer. We instrumented it,
reproduced the failure, and the drop counter stayed at **zero** across a run that
produced three RCU stalls. (Control: hypervisor `printk` demonstrably reaches the
same console — `Initializing unit: irqchip` appears there.) **Hypothesis refuted.**

### Second hypothesis: SGIs are coalesced by ID — CORRECT

In `gicv2_inject_irq()`:

```c
/* Check that there is no overlapping */
lr = gicv2_read_lr(n);
if ((lr & GICH_LR_VIRT_ID_MASK) == irq_id)
        return -EEXIST;
```

It matches on the **virtual interrupt ID alone**. But an SGI's identity is not just
its number — real GICv2 tracks SGI pending state **per source CPU**
(`GICD_SPENDSGIR`/`GICD_CPENDSGIR` are one byte per SGI, one bit per source). Two
CPUs sending SGI 1 to the same target are two distinct interrupts; this code sees
one.

And nothing retries the `-EEXIST`. Both callers treat it as delivered:

```c
/* irqchip_inject_pending(): only -EBUSY is special */
if (irqchip.inject_irq(irq_id, sender) == -EBUSY) { ...; return; }
pending->head = (pending->head + 1) % MAX_PENDING_IRQS;   /* -EEXIST → dropped */

/* irqchip_set_pending(): anything that isn't -EBUSY is "done" */
if (local_injection && irqchip.inject_irq(irq_id, sender) != -EBUSY)
        return;
```

**Instrumented, this caught the failure in the act:**

```
WARN: cpu1 SGI 1 from cpu0 coalesced into an in-flight SGI, dropped (1 so far)
rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
rcu:   rcu_preempt kthread ... ->state=0x200 ->cpu=1
```

Every detail lines up: the dropped SGI is **1** (`IPI_CALL_FUNC`, the ttwu wakeup
IPI), it targets **cpu1**, the kthread stuck in `TASK_WAKING` is on **cpu1**, and
the stall detector fires 21024 jiffies later — its 21-second threshold, i.e. the
grace period stopped advancing at the moment of the drop.

### The complete chain

```
1. CPU0 wakes rcu_preempt, which is assigned to CPU1
2. ttwu_queue_wakelist(): task → CPU1's wake_list, task state = TASK_WAKING
3. send_call_function_single_ipi(1) → GICD_SGIR write → trapped
4. Jailhouse: an SGI 1 is already in one of CPU1's list registers
5. gicv2_inject_irq() matches on ID only → -EEXIST
6. caller advances head → the IPI is DISCARDED
7. CPU1 is never told to drain its wake_list
8. rcu_preempt stays TASK_WAKING forever
9. RCU grace periods stop advancing → board wedges
```

Everything that was previously unexplained now follows:

- **Needs hypervisor + inmate + stressor.** You need Jailhouse (to mediate the
  GIC), enough IPI traffic for a collision, and cell operations to stretch the
  window in which an SGI is in flight.
- **Preemption model irrelevant.** Nothing is starved.
- **Priority knobs useless.** You cannot schedule a task nobody woke.
- **Pausing stressors helped.** Fewer IPIs in the dangerous window → fewer
  collisions. A mitigation, not a cure — and disabling it made things *worse*
  (5 iterations instead of 15), which is why it stayed on.

## 5. Why the KV260 never hit this

The same campaign ran fine on a Kria KV260 with 8 workers. That board's kernel was
built with `CONFIG_PREEMPT_RT=y`, and in the RT patch:

```c
#ifdef CONFIG_PREEMPT_RT
SCHED_FEAT(TTWU_QUEUE, false)
#else
SCHED_FEAT(TTWU_QUEUE, true)
#endif
```

**`PREEMPT_RT` disables `TTWU_QUEUE`.** An RT kernel never uses the remote-wakeup
IPI path, so it never exercises the bug. The KV260 was not more robust — it simply
never sent the interrupt that gets lost.

That also explains a confusing detour. An early theory was "the KV260 ran
`PREEMPT_RT`, the ZCU104 doesn't — that's the difference", which was then
dismissed on the grounds that `PREEMPT_RT` is unbuildable in this tree
(`depends on EXPERT && ARCH_SUPPORTS_RT`, and `arch/arm64/Kconfig` never selects
`ARCH_SUPPORTS_RT` because the RT patch is no longer applied — see
`LINUX_PATCH_ARGS` in `environment_cfgs/*-jailhouse.sh`, and commit `f4fe024e`,
2025-03-11, *"preempt-rt patch is not applied anymore"*).

Both halves were right, and both missed the point: `PREEMPT_RT` really would have
fixed this — not through preemption, but through that one `SCHED_FEAT` line.

## 6. The fixes

### Linux side — workaround, currently in use

```sh
mount -t debugfs none /sys/kernel/debug          # not mounted at boot here
echo NO_TTWU_QUEUE > /sys/kernel/debug/sched/features
```

Wakeups then enqueue directly on the target runqueue under its lock. No
`wake_list`, no IPI, nothing to lose. Requires `CONFIG_SCHED_DEBUG=y` (this kernel
was rebuilt for it; the option was explicitly off despite being `default y`).

**It resets on every boot.** `stressor.sh` reapplies it and aborts loudly if it
cannot — do not remove that block.

Result: `cpu4`, which had never passed 11 of 52 benchmarks, completed **52/52**,
and the full 6-configuration campaign ran **6h20m with zero RCU stalls and no
power cycle**.

### Jailhouse side — the actual fix

`hypervisor/arch/arm-common/gic-v2.c`, in `gicv2_inject_irq()`:

```c
if ((lr & GICH_LR_VIRT_ID_MASK) == irq_id) {
        /*
         * For an SGI the source CPU is part of the interrupt's identity:
         * real GICv2 keeps SGI pending state per source. Matching on the
         * virtual ID alone drops SGIs sent by a different CPU.
         */
        if (!is_sgi(irq_id) ||
            ((lr >> GICH_LR_CPUID_SHIFT) & 0x7) == (sender & 0x7))
                return -EEXIST;
}
```

Distinct senders now get their own list register, or fall back to `-EBUSY` and the
pending ring, which retries correctly.

Measured: the configuration that wedged within 2 minutes ran to completion.

### Second half of the fix: the same-sender case

The sender check above fixed *different* senders. A narrower case remained — **the
same sender, when its previous SGI is still in a list register**:

```
WARN: cpu2 SGI 1 from cpu0 coalesced into an in-flight SGI, dropped (1 so far)
```

On real hardware this is not lossy: setting an SGI's pending bit while that
interrupt is *active* leaves it pending again, so it fires once more after the
guest EOIs. GICv2 list registers model exactly this with a **pending+active**
state (`GICH_LR` bits 29 = active, 28 = pending). Jailhouse ignored it and
discarded the event, so a guest that had already read the IRQ from IAR never
looked again.

```c
/* same sender (or not an SGI): re-arm rather than drop */
if ((lr & GICH_LR_ACTIVE_BIT) && !(lr & GICH_LR_PENDING_BIT)) {
        gicv2_write_lr(n, lr | GICH_LR_PENDING_BIT);
        return 0;
}
/* already pending: genuine coalescing, matches hardware */
return -EEXIST;
```

## 7. Results

All measured on `cpu4` with the same eight benchmarks, everything else identical.

| hypervisor | `TTWU_QUEUE` | SGI drops | RCU stalls | outcome |
|---|---|---|---|---|
| unmodified | on (default) | 1 | 1 | **wedged in ~2 min** |
| sender check only | on | 1 | 1 | completed |
| **both halves** | **on** | **0** | **0** | **completed clean** |
| unmodified | off (`NO_TTWU_QUEUE`) | — | 0 | completed clean |

And the full campaigns, on the workaround:

- 4 workers, 6 configurations × 52 benchmarks: **6h20m, 0 stalls, 0 dropped**
- 8 workers, 6 configurations × 52 benchmarks: **~6h, 0 stalls, 0 dropped**

Note the 8-worker campaign did still trigger **three SGI drops** (all
`SGI 0 = IPI_RESCHEDULE`, which is benign — the next tick recovers). The bug was
firing; `NO_TTWU_QUEUE` only made it harmless by keeping `wake_list` work off the
IPI path. That is the argument for fixing the hypervisor rather than relying on
the workaround.

**With both halves of the fix, `NO_TTWU_QUEUE` is no longer required.** It is
still applied by `stressor.sh`, as belt and braces and because the campaign data
was collected with it.

## 8. Scope

This is `hypervisor/arch/arm-common/` code, not Omnivisor-specific and not specific
to this benchmark. It should affect **any GICv2 Jailhouse guest whose CPUs send
each other SGIs** under enough load — i.e. any SMP Linux root cell. The reason it
is not seen constantly is that it needs a collision inside a narrow window; heavy
IPI traffic plus cell operations is what makes it reachable.

Worth reporting upstream. The fork's history is a squashed merge, so we could not
diff against Siemens upstream to confirm the code is unmodified there.

## 9. Reproducing and verifying

Instrumentation added while investigating (counters in `struct pending_irqs`):

- `dropped` — ring-overflow discards. **Measured 0**; keep it as a guard.
- `sgi_coalesced` — `-EEXIST` SGI discards. **This is the one that fires.**

To reproduce the failure deliberately: install a hypervisor without the fix, set
`TTWU_QUEUE` (the default), and run `cpu4`. It wedges in 2–6 minutes.

To watch it happen, capture the serial console from the console host — it survives
the board becoming unreachable, which is the whole point:

```sh
# on 192.168.100.45
stty -F /dev/zcu104a-01 115200 raw -echo
cat /dev/zcu104a-01 >> /root/zcu104a_logs/capture.log
```

Board environment that these results were taken on:

| | |
|---|---|
| kernel | 6.1.70 `#6`, `PREEMPT`, `HZ=1000`, `NO_HZ_FULL`, `SCHED_DEBUG=y` |
| cmdline | `isolcpus=domain,managed_irq,3 skew_tick=1 deferred_probe_timeout=1` |
| rootfs | SD (`/dev/mmcblk0p2`) |
| workaround | `NO_TTWU_QUEUE`, applied by `stressor.sh` |

> **Do not put `nohz_full=3 rcu_nocbs=3 rcu_nocb_poll` on the cmdline.** CPU 3
> belongs to Jailhouse — Linux has it hotplugged out — so those only move RCU
> callback work onto the measured cores 0–2 and add a polling kthread. Removing
> them alone took `cpu4` from 20–45 s to 16 minutes before any of the above.
