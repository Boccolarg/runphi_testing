# runPHI-KVM vs runc on the Kria KV260

A reproduction, on the Kria KV260, of the experimental campaign of
*Extending Zero-Interference Containers with Kernel-based Virtual Machine*
(Capone, Cecchini, Colucci, RTIS 2026; `runphi_kvm_doc.pdf` and
`runPHI-presentation.pdf`). The students ran it on three x86_64 PCs. Here the
same experiments run on one ARM board, with runPHI's `backend_kvm` built for
aarch64 (runphi_manager PR #4) and the `kria-kvm` environment of
environment_builder.

There are two experiments:

- **Freedom from interference** (`ffi_*`). `cyclictest` runs in a container
  on the isolated CPU, either an ordinary runc container or a runPHI-KVM
  guest, while `stress-ng` loads the other CPUs with one of 9 profiles (plus
  an unstressed baseline). 30 runs per runtime and profile.
- **Lifecycle** (`life_*`). `docker create`, `start`, `stop` and `rm` are
  timed for both runtimes, with cold and warm caches. 30 runs each.

The campaign was run twice:

- **First campaign.** The students' own scripts were not available yet, so its
  method is reconstructed from the paper and the slides. Every guess is
  listed in [Assumptions](#assumptions-reconstructed-from-the-paper).
- **Second campaign.** When the scripts arrived, it repeated the campaign
  following them step by step; see
  [The students' own scripts](#the-students-own-scripts-m4_scripts).

## Results

The first campaign was measured on 2026-10-02/03, with the setup below: 24
campaigns of 30 runs each. runc was measured once. runPHI-KVM was measured
with runphi_manager `174a3c9`, which keeps QEMU's own threads off the vCPU's
CPU (see
[Teardown livelock](#teardown-livelock-of-runphi-kvm-guests-found-in-the-first-campaign)).
The second campaign, with the students' procedure, is
[further down](#second-campaign-results).

The tables come from `analysis/analyze.py`. The raw data is not in the
repository: it is on the workstation in `data/run-2026-10-03/` (first
campaign) and `data/run-2026-10-06-m4/` (second), and on the board's SD card
in `/root/rtbench` (`results/` and `results_m4/`).

### Lifecycle (mean of 30 runs, ms)

| Runtime | Caches | Create | Start | Stop | RM | **Total** | Start → ready |
|---|---|---|---|---|---|---|---|
| runc | cold | 1317 | 1831 | 360 | 94 | **3602** | 58 |
| runc | warm | 354 | 852 | 360 | 80 | **1647** | 55 |
| runPHI-KVM | cold | 1273 | 11081 | 1676 | 95 | **14124** | 2214 |
| runPHI-KVM | warm | 322 | 7545 | 1304 | 87 | **9258** | 2207 |

Compared with the students' x86 PCs:

- runc takes 1.6 s warm here, against 0.4–0.5 s there.
- runPHI-KVM takes 9.3 s warm here, against 1.9–3.3 s there.
- Most of runPHI's time is `docker start`, which creates the paused VM,
  locks its 1 GB of RAM, sets up the cgroup and pinning, and resumes it:
  7.5 s warm on the 1.33 GHz Cortex-A53. The paper's "start" phase does not
  include the guest's boot. That boot is the last column: 2.2 s from
  `docker start` returning to the guest's `RTBENCH READY`.

### cyclictest on the isolated CPU 3 (µs)

The table shows, per profile, the median over runs of each run's average
latency, and the mean and worst over runs of each run's maximum latency.

| Profile | runc avg | runc max mean | runc max worst | runPHI-KVM avg | runPHI-KVM max mean | runPHI-KVM max worst |
|---|---|---|---|---|---|---|
| baseline | 7 | 12.1 | 14 | 27 | 59.8 | 79 |
| matrixprod | 7 | 15.4 | 18 | 31 | 81.4 | 113 |
| callfunc | 7 | 12.1 | 15 | 27 | 59.7 | 81 |
| irq (timer) | 7 | 12.0 | 13 | 28 | 62.1 | 84 |
| memcpy | 7 | 12.3 | 16 | 27 | 57.8 | 85 |
| stream | 47.5 | 75.8 | 101 | 210.5 | 296.1 | 348 |
| tlb_shootdown | 18 | 59.8 | 77 | 125 | 354.0 | 445 |
| hdd_sync | 7 | 12.6 | 22 | 27 | 72.7 | 104 |
| io_uring | 7 | 12.5 | 14 | 28 | 79.4 | 110 |
| socket (UDP) | 7 | 12.7 | 15 | 29 | 72.5 | 87 |

- **runc is barely touched by CPU and I/O stress.** With the isolation
  settings, it stays at 7 µs average and 12–15 µs mean maximum under every
  CPU and I/O profile. CPU 3 takes about 1,120 interrupts/s in every
  profile, essentially cyclictest's 1 kHz timer: the stressors on CPUs 0–2
  do not reach it.
- **runPHI-KVM pays a constant price for virtualization.** It adds about
  20 µs to the average and about 45 µs to the maximum. Each timer expiry
  goes through the host, which wakes the vCPU thread, then a full EL1/EL2
  world switch (the A53 has no VHE), then the guest's own interrupt and
  wakeup. CPU and I/O stress add little on top of that: 58–81 µs mean
  maximum.
- **Memory contention reaches both runtimes, and runPHI-KVM much more.**
  `stream` and `tlb_shootdown` contend for hardware all four cores share:
  the 1 MB L2 cache, the DRAM controller, and TLB maintenance, which arm64
  broadcasts in hardware. runc reaches 76 and 60 µs mean maximum; runPHI-KVM
  reaches 296 and 354 µs, with averages of 210 and 125 µs. Two-stage address
  translation makes every TLB miss and invalidation in the guest more
  expensive.
- **On the KV260, runc beats runPHI-KVM in every profile.** The paper's
  claim that runc "collapses" under synchronous I/O (714 µs spikes) is not
  reproduced: runc's worst case under any I/O profile is 22 µs. The
  students' own figures also show runc below runPHI-KVM in almost every
  profile, and runPHI-KVM's worst case there (up to 117 µs) is in the same
  range as here.

### Effect of the runPHI fix (emulator pinning)

Eight cyclictest profiles (all but `memcpy` and `hdd_sync`) and both
lifecycle campaigns were also measured with the old runPHI (`5ced581`, in
`results_runphi-5ced581/`). Old and new agree within run-to-run variation; for
example, the baseline's mean maximum is 58.5 µs with the old runPHI and
59.8 µs with the new one, and `stream`'s is 304.6 and 296.1 µs. The fix
changes teardown, not latency. With the old runPHI, a guest powering off
hung its container in 3 of 30 `matrixprod` runs, and had aborted 3
campaigns in the first night. With the fix it never happened in 300 runs:
`qemu_killed` was never needed.

### The students' own scripts (M4_SCRIPTS)

The students' scripts arrived after the campaign above, in
`runphi_testing/M4_SCRIPTS`, from their PC1, the one with CPU 3 isolated:

| Script | Role |
|---|---|
| `auto_test.sh` | runs one experiment per boot |
| `prepare_host.sh` | applies the host settings |
| `run_no_interference.sh` | steady state, no stress |
| `run_{cpu,mem,io}_stress.sh` | the stress profiles |
| `run_latency_start_stop.sh` | lifecycle |

They answer most of the [assumptions](#assumptions-reconstructed-from-the-paper),
and show that the paper describes some steps differently from what was run:

| | Paper / slides | Their scripts | First campaign above |
|---|---|---|---|
| Warm-up before cyclictest | "30 s warm-up" | **none**: stress-ng and vmstat start, 2 s pause (1 s for steady), then `docker run`; cyclictest runs as soon as the container (or guest) is up | 30 s after `RTBENCH READY` |
| Container start under stress | not stated | **yes**: it is inside the stressed window, 60 s of stress-ng in total | no |
| cyclictest | `-p 99 -i 1000 -l 30000 -m -a <cpu> -q` | the same plus **`-h 1000`** (histogram; output is `# Min/Avg/Max Latencies:` instead of the `T:` line) | without `-h` |
| runPHI guest | | runPHI does not run the container command, so the guest runs whatever its image (`rt-cyclictest:runphi`, not available) runs at boot; `docker wait` until it powers off | waits 30 s, then cyclictest |
| matrixprod / callfunc / irq | | `--cpu 3 --cpu-method matrixprod/callfunc`, `--timer 3 --timer-freq 1000000` | the same |
| memcpy | "1 GB memory copying" | `--memcpy 3 --vm-bytes 384M --vm-keep` (the `--vm-*` options do not apply to `--memcpy`: effectively `--memcpy 3`) | the same |
| tlb_shootdown / stream / socket | | `--tlb-shootdown 3`, `--stream 3`, `--udp 3` | the same |
| hdd_sync | paper: "random writes (256 MB) + sync()"; slides: O_DIRECT random reads | **`--hdd 3 --hdd-bytes 512M --hdd-opts direct,rd-rnd,noatime`** on `/var/tmp/stress_ssd` (disk) | `--hdd-bytes 256M --hdd-opts wr-rnd,fsync`: **different** |
| io_uring | | **`--io-uring 3 --temp-path /tmp`**: tmpfs on the Arch PCs (1, 3), disk on Ubuntu (PC2) | SD card: **different** |
| Stressor pinning | CPUs 0-2 | `taskset -c 0-2 stress-ng ...` | `--taskset 0-2` (the same) |
| Order | | each iteration runs runc and then runPHI, in the same boot; one boot per profile | one boot per runtime and profile |
| vmstat | 1 Hz | `vmstat -t 1` for the whole run, container start included | cyclictest window only |
| Lifecycle | create/start/stop/rm | `docker create` (with the cyclictest command), `start`, **`sleep 1`**, `stop -t 10`, `rm`; cold: `sync` + `drop_caches` before each run; warm: no discarded first run; vmstat running; runc and runPHI alternate | READY + 2 s before stop, a discarded warm-up run |
| Host settings | | `prepare_host.sh`: deep C-states off and frequency fixed on CPU 3, `sched_rt_runtime_us = -1`, `timer_migration = 0`, every IRQ's affinity to 0-2 at runtime | the same (the IRQ step added to `rt_tune.sh`) |

The scripts work, with two weak points in how they check their own
results:

- **A failed run is recorded as zero.** If the runPHI serial log is
  missing, the parser reads the QEMU log or nothing. It then records 0 for
  Min/Avg/Max without an error.
- **Nobody checks that the stress actually ran.** stress-ng's output and
  exit status go to `/dev/null`, so a stressor that fails (as stress-ng
  0.15's io_uring does on this board) leaves an unstressed run that looks
  like a stressed one.

`auto_test.sh` numbers its steps inconsistently (1/12, 2/9, ...), which is
only cosmetic.

**Second campaign: the students' procedure.** `bench/m4.py` performs the
scripts' steps on the board. The scripts cannot run there unchanged: busybox
has no `taskset`, `grep -P` or `date +%N`. The replica runs as campaigns
`m4_*` (`bench/queue.m4`, their order, one per boot) and writes its results
to `results_m4/`. It deviates from the scripts in three places:

- **hdd_sync directory.** Their `hdd_sync` directory `/var/tmp/stress_ssd`
  is on the PC's disk, but on the board `/var/tmp` is the tmpfs `/tmp`, so
  the replica uses `/root/rtbench/stress_ssd` on the SD card. `io_uring`
  uses `/tmp` as in the scripts, which is tmpfs on the board as on their
  Arch PCs.
- **Stress timeout.** Their stress-ng `--timeout 60s` assumes x86's 2 s
  container start. runPHI needs 9–45 s to start a guest under stress on the
  KV260, so the timeout is 180 s. stress-ng is still stopped after every
  run, as theirs.
- **runPHI guest.** The guest runs, at boot,
  `cyclictest -p 99 -i 1000 -l 30000 -m -a 0 -q -h 1000` (`images/kvm/S99m4`;
  `-a 0` is the guest's only vCPU), then powers off. That is an assumption:
  their guest image is not available.

`rt-cyclictest:runc` (`images/runc/Dockerfile.m4`) holds the same cyclictest
binary as the first campaign, without the entrypoint.

#### Second campaign results

Measured on 2026-10-06: 12 campaigns, one per boot, each with 30 iterations
of runc and then runPHI-KVM. All 600 cyclictest runs and 120 lifecycle runs
completed, and the data checks passed:

- no guest had to be killed (`qemu_killed`);
- stress-ng was still running at the end of all 540 stressed runs;
- their parse (the first `Min:` / `# Min Latencies:` match) agreed with the
  histogram's summary in every run.

Lifecycle (mean of 30 runs, ms):

| Runtime | Caches | Create | Start | Stop | RM | **Total** | First campaign |
|---|---|---|---|---|---|---|---|
| runc | cold | 1377 | 1802 | 453 | 84 | **3716** | 3602 |
| runc | warm | 370 | 897 | 410 | 88 | **1765** | 1647 |
| runPHI-KVM | cold | 1324 | 11027 | 1669 | 90 | **14109** | 14124 |
| runPHI-KVM | warm | 393 | 7592 | 1315 | 81 | **9382** | 9258 |

The lifecycle times agree with the first campaign within 7%. Their
procedure differs in three ways: it sleeps 1 s before stop, keeps vmstat
running, and keeps the first warm run. None of these changes much.

cyclictest on the isolated CPU 3 (µs), in the same form as the first
campaign's table:

| Profile | runc avg | runc max mean | runc max worst | runPHI-KVM avg | runPHI-KVM max mean | runPHI-KVM max worst |
|---|---|---|---|---|---|---|
| baseline | 7 | 11.8 | 17 | 28 | 65.3 | 89 |
| matrixprod | 8 | 15.4 | 20 | 35 | 92.7 | 109 |
| callfunc | 7 | 13.2 | 17 | 28 | 68.1 | 96 |
| irq (timer) | 7 | 12.4 | 16 | 28 | 67.1 | 75 |
| memcpy | 7 | 12.9 | 17 | 28 | 67.0 | 94 |
| stream | 47 | 71.3 | 96 | 208 | 333.5 | 381 |
| tlb_shootdown | 21 | 168.1 | 234 | 126 | 343.1 | 383 |
| hdd_sync | 7 | 11.6 | 12 | 28 | 72.2 | 89 |
| io_uring | 7 | 13.9 | 24 | 30 | 90.1 | 138 |
| socket (UDP) | 7 | 13.2 | 21 | 29 | 78.7 | 105 |

- **The first campaign's conclusions hold.** runc beats runPHI-KVM in every
  profile. CPU and I/O stress barely reach runc: at most 15 µs mean maximum
  and 24 µs worst case. Memory stress hurts runPHI-KVM the most.
- **runc does not collapse under I/O with the students' own `hdd_sync`
  either.** With their exact options (O_DIRECT random reads, 512 MB), runc's
  worst case is 12 µs. The difference between paper and scripts therefore
  does not explain the paper's 714 µs spikes, at least on this board.
- **runPHI-KVM is a little higher in most profiles.** Its mean maximum is
  5–11 µs higher in seven profiles and 37 µs higher in `stream`;
  `tlb_shootdown` and `hdd_sync` are unchanged. The guest differs from the
  first campaign in two ways: cyclictest starts as soon as the guest's init
  reaches it instead of 30 s later, and it runs with `-h 1000`. Which of the
  two matters was not measured.
- **runc under `tlb_shootdown` is worse because of the alternating order.**
  Its mean maximum is 168 µs, against 60 µs in the first campaign. The
  first runc run of the boot, before any runPHI guest, reached 66 µs. Each
  of runs 2–30 came after a runPHI guest in the same boot, and they reached
  115–234 µs, with about 500 samples above 60 µs each.
  `bench/order_probe.py` confirmed this on a fresh boot, with 5 runc runs,
  1 runPHI run, then 5 runc runs, all under `tlb_shootdown`:

  | | Max | Samples > 60 µs |
  |---|---|---|
  | runc before the guest | 56–68 µs | 0–4 |
  | runc after the guest | 165–190 µs | 484–591 |

  The effect lasts for the rest of the boot, and of the profiles measured
  it shows up only under `tlb_shootdown`: `stream`, the other memory
  stressor, is unaffected. In the first campaign every runc campaign ran in
  a boot without guests, so its runc numbers are not affected.

  Four more variants of the probe narrow down the cause. Each ran on its
  own fresh boot: 3 runc runs, the step in the first column, 3 more runc
  runs, all runc runs under `tlb_shootdown` (`order_probe.py <variant>`,
  campaigns `probe_*`):

  | Between the runc runs | runc max, before → after | Samples > 60 µs |
  |---|---|---|
  | runPHI guest, no stress while it runs (`runphi`) | 63–93 → 167–179 µs | 2–43 → 434–561 |
  | plain QEMU/KVM guest, without libvirt or runPHI, on CPU 3 (`qemu_cpu3`) | 56–64 → 163–186 µs | 0–4 → 426–638 |
  | the same guest on CPU 2, so nothing of KVM runs on CPU 3 (`qemu_cpu2`) | 52–66 → 146–170 µs | 0–4 → 353–438 |
  | plain QEMU/KVM VM created paused on CPU 3, its vCPU never runs (`qemu_paused`) | 55–64 → 56–72 µs | 0–1 → 0–1 |

  - **It is KVM, not runPHI or libvirt.** A plain QEMU guest does the same,
    and the stress does not have to run while the guest does.
  - **It is not a change to CPU 3.** A guest that only ever ran on CPU 2
    slows runc on CPU 3 just as much.
  - **Creating a VM is not enough.** A guest has to run, on any CPU (and,
    as the next probes show, it has to be more than a tiny one).
  - **CPU 3 does not get more work.** It takes the same interrupts before
    and after, about 950/s (its timer, IRQ work and function-call IPIs).
    No VM is left in KVM (debugfs), no process is left behind, and this
    kernel has no transparent huge pages.

  So what `tlb_shootdown` already does on CPUs 0–2 becomes about three
  times more expensive for CPU 3 once a guest has run on the board.

  Three more variants look inside. In these, every runc run also counts
  the PMU events of each CPU (`bench/pmucount.c`: the board has no `perf`):

  | Between the runc runs | runc max, before → after | Samples > 60 µs |
  |---|---|---|
  | plain QEMU/KVM guest on CPU 3 again, with the counters (`qemu_cpu3`) | 64–79 → 100–180 µs | 1–22 → 473–642 |
  | the same guest without a virtual PMU, `-cpu host,pmu=off` (`qemu_nopmu`) | 56–74 → 132–188 µs | 0–7 → 493–701 |
  | a tiny guest that writes one line and powers off at once (`qemu_tiny`, `bench/tiny_guest.S`) | 65–90 → 60–83 µs | 1–23 → 0–20 |

  CPU 3 during the runc runs (per second, mean of 3 runs, before → after):

  | Guest | Cycles | Instructions | Cycles per instruction | L1D / L1I TLB refills | L2 refills | Exceptions | Load-miss stall cycles |
  |---|---|---|---|---|---|---|---|
  | `qemu_cpu3` | 65 → 110 M | 11.5 → 11.5 M | 5.7 → 9.6 | 755 / 269 → 803 / 312 | 135 k → 117 k | 1917 → 1923 | 5.3 → 7.8 M |
  | `qemu_nopmu` | 59 → 114 M | 11.2 → 11.6 M | 5.3 → 9.8 | 763 / 278 → 951 / 319 | 116 k → 126 k | 1864 → 1947 | 5.7 → 8.2 M |
  | `qemu_tiny` | 64 → 65 M | 11.5 → 11.6 M | 5.6 → 5.6 | 920 / 379 → 827 / 322 | 134 k → 125 k | 1917 → 1940 | 5.6 → 5.7 M |

  - **It is not the virtual PMU.** The guest without one has the same
    effect.
  - **It is not KVM entering a guest.** The tiny guest goes through KVM's
    whole first run (VMID, timer, vGIC, a world switch, PSCI) and leaves
    nothing behind. Something the guest's Linux does while it runs causes
    the change: its MMU and caches, its own TLB maintenance (broadcast,
    with the guest's VMID), its use of memory, the vGIC and the timer, or
    simply running for 40 s.
  - **CPU 3 does the same work, only more slowly.** After a Linux guest, CPU
    3 retires the same instructions and takes the same exceptions, with
    about the same TLB and cache refills, but needs 75–90% more cycles
    (CPI 5.5 → 9.7). The extra 45–55 M cycles/s are not load-miss stalls
    (+2.5 M) and not TLB refills (+50 to +190/s). They match the core
    stalling while it processes the TLB maintenance broadcast by CPUs 0–2,
    which become slower to complete. CPUs 0–2 also retire 4–8% fewer
    instructions after a Linux guest.

  The exact mechanism, in KVM or in the Cortex-A53 and its interconnect,
  is not identified. For runPHI-KVM, this is interference that outlives the
  guest: once a KVM container has run, a plain container on the isolated
  CPU loses latency under TLB-heavy load, until the next reboot.

Still open, for the students:

- what their runPHI guest runs at boot (the exact cyclictest command, any
  delay);
- how their runc image got cyclictest onto Alpine;
- their stress-ng and rt-tests versions;
- how the vmstat files were averaged;
- their raw data;
- whether their runc results under memory stress change when runc runs in
  a boot without runPHI guests (see the last point above).

Reproduce the tables and figures with:

```sh
# first campaign, with the comparison against the old runPHI
python3 analysis/analyze.py data/run-2026-10-03/results out \
    --compare data/run-2026-10-03/results_runphi-5ced581 "old runPHI 5ced581"
# second campaign, with the comparison against the first
python3 analysis/analyze.py data/run-2026-10-06-m4/results_m4 out-m4 \
    --compare data/run-2026-10-03/results "first campaign"
```

## Setup

### Board

| | |
|---|---|
| Board | Kria KV260: 4 × Cortex-A53, 1.333 GHz, 4 GB RAM (3.7 GB usable), GIC-400 |
| Host kernel | Linux 6.1.70-rt21 `PREEMPT_RT`, `HZ=1000`, `NO_HZ_FULL`, `RCU_NOCB_CPU`, KVM in nVHE mode (the A53 has no VHE) |
| Boot | **from the SD card** (`/root/boot_mode.sh sd`): kernel, DTB and root filesystem (ext4, `mmcblk1p2`) |
| Docker | 23.0.5, `overlay2` on the same SD card, cgroup v1; runtimes `runc` (default) and `runphi` |
| runPHI | `backend_kvm` → libvirt 7.10 → QEMU 8.0.2 (`virt` machine, GICv2) |

Why SD and not NFS: on the TFTP+NFS boot, every executable on the container
start path is read over NFS (`docker`, the shims, `runc`, `runphi`, `virsh`,
19.8 MB of `qemu-system-aarch64` plus 27 libraries), with `rsize=4096`. Even
warm runs then pay an NFS round trip on every `open`/`exec`
(close-to-open consistency), and runPHI runs more programs than runc. NFS
would also change what the I/O stressors do: their files would go over the
network instead of to a block device. Booted from the SD card, the system
looks like a deployed embedded board, with one local disk, as the students'
PCs had one local disk.

### Isolation and tuning: the students' settings on the KV260

CPU 3 is isolated. CPUs 0–2 are the housekeeping CPUs, as on the students'
4-core PC1.

| Students (x86) | KV260 |
|---|---|
| `isolcpus=managed_irq,domain,nohz,<c> nohz_full=<c> rcu_nocbs=<c>`, `irqaffinity=` the other cores | the same arguments, with `<c>` = 3 and `irqaffinity=0,1,2`. They are written to `isolargs.txt` on the SD card's FAT partition by `/root/boot_mode.sh iso 3`, and both boot scripts read that file (see environment_builder, `kria/kvm`). |
| SMT off (`nosmt`) | not applicable: the A53 has no SMT |
| C-states: `processor.max_cstate=1 intel_idle.max_cstate=0` | not needed: the kernel has no `CPU_IDLE`, so idle CPUs only use WFI |
| frequency fixed (governor `performance`, no turbo) | only the `userspace` governor exists, so the frequency is fixed at `cpuinfo_max_freq` = 1.333 GHz |
| `sched_rt_runtime_us = -1` | the same |
| `timer_migration = 0` | the same |
| headless | the board is headless |
| reboot between test campaigns | the board reboots before every campaign |

`bench/rt_tune.sh` applies the runtime settings after every boot and checks
all of the above. If a check fails, the campaign does not start. Its output is
saved with each campaign (`host_state_boot*.txt`). After isolation, the only
interrupt that can still fire on CPU 3 is its own PMU interrupt (`arm-pmu`,
per-CPU), apart from the per-CPU timer and IPIs.

### Containers

Both runtimes get the students' Docker options:

```
--cpuset-cpus 3 -m 1024m --network none --cap-add SYS_NICE --ulimit rtprio=99 --ulimit memlock=-1
```

and run the same command:

```
cyclictest -p 99 -i 1000 -l 30000 -m -a <cpu> -q
```

That is SCHED_FIFO 99, a 1 ms period and 30,000 loops (30 s), with memory
locked and one thread pinned to the isolated CPU. `<cpu>` is 3 for runc. For
the guest it is 0, the guest's only vCPU, which runPHI pins to host CPU 3.

| | runc | runPHI-KVM |
|---|---|---|
| Image | `rtbench-runc:alpine` (`images/runc`): Alpine 3.24 and cyclictest only | `rtbench-kvm:full` (`images/kvm`): kernel and initramfs, plus `/boot/config.json`. QEMU's own threads run on CPUs 0-2 (runPHI's emulator pinning, see [Teardown livelock](#teardown-livelock-of-runphi-kvm-guests-found-in-the-first-campaign)) |
| cyclictest | rt-tests 2.5 (`V 2.50`), static, glibc | rt-tests 2.5 (`V 2.50`), from Buildroot 2023.05, glibc |
| Kernel | the host's | a copy of the host's `Image` (6.1.70-rt21 `PREEMPT_RT`), booted as a QEMU `virt` guest |
| Configuration | the Docker options above | the students' `config.json`: `"memory": 1024`, `"net": "no"`, `"vcpus": 1`, vCPU 0 pinned to CPU 3 (runPHI gives it SCHED_FIFO 99), `"steer_irq": [0,1,2]` |

The runc image has its cyclictest built against glibc, not musl. Alpine has no
rt-tests package, and a musl build fails here in two ways:

- `sched_getscheduler()` returns ENOSYS in musl, so cyclictest stops with
  `unable to get scheduler parameters`.
- libnuma sizes its CPU masks with `sysconf(_SC_NPROCESSORS_CONF)`, which
  musl computes from the affinity mask. Inside `--cpuset-cpus 3` that is one
  CPU, so `-a 3` is "out of range". The arm64 kernel has no NUMA sysfs that
  libnuma could use instead.

The guest initramfs is the one of the existing runPHI test images, with the
network services removed (the guest has no network device) and
`S99rtbench` added. The container's `rtbench.sh` and the guest's
`S99rtbench` do the same thing: print `RTBENCH READY`, sleep for the warm-up,
then run cyclictest. The guest then powers off, which ends the container.

### Stressors

stress-ng 0.22.01, built statically for aarch64 (`/root/rtbench/bin/stress-ng`;
on the PC: `git clone --depth 1 --branch V0.22.01
https://github.com/ColinIanKing/stress-ng.git && make CC=aarch64-linux-gnu-gcc
STATIC=1`).
The board's own 0.15.07 aborts its io_uring stressor (an `IORING_OP_STATX`
fails with ENOENT), so one newer binary is used for every profile. All
profiles add
`--taskset 0-2 --temp-path /root/rtbench/stress-tmp --timeout <s> --metrics-brief`.
The temporary files are on the SD card, the board's only disk.

| Profile | stress-ng | Paper |
|---|---|---|
| `baseline` | none | no stress |
| `matrixprod` | `--cpu 3 --cpu-method matrixprod` | ALU/FPU, L1/L2 |
| `callfunc` | `--cpu 3 --cpu-method callfunc` | recursive 8-argument calls, depth 1024 |
| `irq` | `--timer 3` | high-frequency POSIX timer interrupts |
| `memcpy` | `--memcpy 3` | memory copying, bus and write-back |
| `stream` | `--stream 3` | STREAM triad, DRAM bandwidth |
| `tlb_shootdown` | `--tlb-shootdown 3` | unmapping, cross-CPU TLB-flush IPIs |
| `hdd_sync` | `--hdd 3 --hdd-bytes 256M --hdd-opts wr-rnd,fsync` | random writes (256 MB) and sync, page cache write-back |
| `io_uring` | `--io-uring 3` | asynchronous ring-buffer submissions |
| `socket` | `--udp 3` | UDP flooding, network softIRQs |

### One cyclictest run (`ffi_<runtime>_<profile>`)

1. `docker run -d` the container or guest. The start-up is not part of the
   measurement.
2. When `RTBENCH READY` appears on its console (the container log, or the
   guest's serial log), start `vmstat -n 1` and the stressors.
3. The container or guest waits 30 s (warm-up), then runs cyclictest for 30 s.
4. When cyclictest prints its summary, stop the stressors and vmstat. The
   container exits by itself (the guest powers off). Then `docker rm`, and
   check that nothing is left behind: no container, no libvirt domain, no
   `/run/runPHI` state.

Per run, the harness records Min, Act, Avg and Max (µs) and the vmstat means
(`in`/s, `cs`/s) over the cyclictest window, as the students did. It also
records the interrupt rate on CPU 3 during that window, which the students
did not measure. While the run lasts, raw data goes to tmpfs, and only
afterwards to the SD card.

### One lifecycle run (`life_<runtime>_<cold|warm>`)

- **Cold:** `sync; echo 3 > /proc/sys/vm/drop_caches` before every run.
- **Warm:** one discarded run first, then 30 runs back to back.

Each run times `docker create`, `docker start`, `docker stop` and `docker rm`
with CLOCK_MONOTONIC around each docker command. `total_ms` is their sum, as
in the students' Table II. The run waits for `RTBENCH READY` (polled every
10 ms) and 2 s more before `docker stop`, so that it stops a running workload.
The time from `docker start` returning to READY is recorded as `ready_ms`.
The students' "start" does not include the guest boot: `docker start` returns
as soon as runPHI has resumed the paused VM (`virsh resume`). `ready_ms` is
that boot.

### Teardown livelock of runPHI-KVM guests (found in the first campaign)

Sometimes a runPHI-KVM container does not end after its guest powers off,
and `docker stop`/`rm` then hang for good. In the first campaign this
happened 6 times in about 300 guest runs, all under `matrixprod`, `memcpy`
and `hdd_sync`. The sequence, observed live on 2026-10-03:

1. The guest powers off (PSCI `SYSTEM_OFF`, last console line
   `reboot: Power down`).
2. The vCPU thread (`CPU 0/KVM`, SCHED_FIFO 99) stays inside `KVM_RUN`
   (`kvm_arch_vcpu_ioctl_run`). It sleeps and wakes about 80,000 times per
   second and keeps CPU 3 at 100 % system time.
3. QEMU's main thread is SCHED_OTHER, and the container's cpuset
   (`--cpuset-cpus 3`) confines it to CPU 3 as well. With
   `sched_rt_runtime_us = -1` it never gets CPU time: it stays runnable
   (`R`), with no CPU time accumulating.
4. QEMU, started by libvirt with `-no-shutdown`, therefore neither exits nor
   answers libvirt, and the domain stays `running`. runPHI's `kill` waits
   forever in `virsh suspend`, so `docker rm -f` hangs.
5. Killing QEMU (`kill -9`) resolves everything: the watcher exits,
   `docker rm` completes, and the IRQs and the cgroup are restored.

The "libvirtd socket missing" errors in runPHI's log from that night were a
consequence, not the cause. The harness gave up and rebooted the board, and
the reboot stopped libvirtd while runPHI was still trying `virsh destroy`.

The measurement is already complete when this happens, so the harness
handles it. If the guest has powered off and its container is still running
15 s later, the harness saves the QEMU threads' state to `run_NN/livelock.txt`,
kills QEMU, and marks the run `"qemu_killed": true`. `poweroff_to_exit_s`
records the normal teardown time. With the old runPHI, a complete
`ffi_kvm_matrixprod` campaign needed this 3 times in 30 runs.

**Fixed in runPHI** (runphi_manager, backend_kvm "emulator pinning"): with
pinned vCPUs, QEMU's other threads now go to CPUs without a pinned vCPU,
through libvirt's `<emulatorpin>`. For this campaign those are the
housekeeping CPUs 0-2. runPHI re-pins them after the cgroup move, and adds
those CPUs to the container's cgroup cpuset. The vCPU keeps CPU 3 to itself;
with `--cpuset-cpus 3` the container's cgroup cpuset becomes `0-3`. All
runPHI-KVM campaigns were re-run with it (binary md5 `a59e6526…`, recorded in
each campaign's `host_state_boot*.txt`). runc does not involve runPHI, so the
runc campaigns were not repeated.

| Directory on the board | Contents |
|---|---|
| `results/` | the campaign: runc (first run) and runPHI-KVM with emulator pinning |
| `results_runphi-5ced581/` | runPHI-KVM before the fix (runphi_manager `5ced581`): 8 complete profiles and both lifecycle campaigns |
| `results_partial/` | the first, aborted attempts at `ffi_kvm_{matrixprod,memcpy,hdd_sync}` with the old runPHI (7, 7 and 9 runs) |

`analysis/analyze.py results out --compare results_runphi-5ced581 "before the
fix"` adds a before/after comparison (`comparison.png`), for each runtime
measured in both directories.

### Data checks

`analysis/analyze.py` re-reads every cyclictest summary from the run's raw
console log, and the console log wins over `runs.jsonl`. In the first
campaign, one value had been recorded from a half-written serial line
(`ffi_kvm_tlb_shootdown` run 17: max 36 instead of 367 µs). The harness now
waits for the complete line.

## Layout

```
images/runc/     Dockerfile + rtbench.sh          -> rtbench-runc:alpine
images/kvm/      build_guest_image.sh, S99rtbench, mkcpio.py -> rtbench-kvm:{full,quick}
bench/rtbench.py one campaign (resumable); rtbench.py check
bench/rt_tune.sh host tuning + checks
bench/orchestrate.sh, S99rtbench   unattended queue, one campaign per boot
bench/queue      the campaign order
bench/validate.sh one short run of everything (results_quick/)
bench/queue.kvm  the runPHI-KVM campaigns only (the re-run with emulator pinning)
bench/emulatorpin_check.sh  on-board check of runPHI's emulator pinning
bench/m4.py      the students' own procedure (M4_SCRIPTS), campaigns m4_* -> results_m4/
bench/queue.m4, bench/validate_m4.sh  its queue (their order) and quick validation
bench/order_probe.py  runc under tlb_shootdown before and after a guest (M4 procedure), variants probe_*
bench/pmucount.c, bench/tiny_guest.S  its PMU counter reader and its smallest guest (-> /root/rtbench/bin)
images/runc/Dockerfile.m4, images/kvm/S99m4  its images: rt-cyclictest:runc, rt-cyclictest:runphi
watchdog/rtbench_watchdog.sh   on the server: power-cycles a hung board, fetches the results
```

On the board everything lives in `/root/rtbench` (SD card), and
`bench/S99rtbench` is installed as `/etc/init.d/S99rtbench`.

## Running it

Board prerequisites (already done): SD boot with isolation,
`/root/boot_mode.sh sd iso 3 -r`. Images: `docker build -t
rtbench-runc:alpine images/runc` and `images/kvm/build_guest_image.sh full`
(plus `quick 5 5000` for the validation), on the board.

Start the unattended queue:

```sh
# on the board
cp /root/rtbench/bench/queue /root/rtbench/queue
rm -f /root/rtbench/state/{done,failed,FINISHED,DISABLED_REASON,boots,attempts.*}
touch /root/rtbench/state/ENABLED && reboot
# on the server (192.168.100.45), as root
screen -dmS rtbench-watchdog /root/rtbench_watchdog.sh
```

From then on the board boots, runs the next campaign of `queue`, and
reboots, until the queue is empty. A campaign that stops halfway, for example
because the watchdog power-cycled the board, continues from its last completed
run.

The second campaign (the students' procedure) runs the same way with
`bench/queue.m4` as `queue`. Its images are built on the board, after
`rtbench-runc:alpine`:

```sh
docker build -t rt-cyclictest:runc -f images/runc/Dockerfile.m4 images/runc
images/kvm/build_guest_image.sh runphi 0 30000 S99m4 rt-cyclictest
images/kvm/build_guest_image.sh runphi-quick 0 3000 S99m4 rt-cyclictest   # for validate_m4.sh
```

| | |
|---|---|
| Progress | `cat /root/rtbench/state/done`; `tail /root/rtbench/logs/orchestrate.log /root/rtbench/logs/<campaign>.log` |
| Stop after the current campaign | `rm /root/rtbench/state/ENABLED` (the watchdog then exits too) |
| Stop now | `rm /root/rtbench/state/ENABLED`, then `pkill -f orchestrate.sh; pkill -f rtbench.py`, then `python3 /root/rtbench/bench/rtbench.py check` and clean up the `rtb-*` containers |
| Results | `/root/rtbench/results/<campaign>/runs.jsonl` and `run_NN/` (`results_m4/` for the second campaign); copied to `/root/rtbench-kv260` on the server when the queue finishes |

## Assumptions (reconstructed from the paper)

Points the paper and slides leave open. Their scripts arrived later and
answer all five (point 5: yes, runPHI got the same Docker options): see [The students' own scripts](#the-students-own-scripts-m4_scripts).

1. **The exact stress-ng command lines.** The number of workers (here one
   per housekeeping CPU) and the options of each profile. In particular:
   - `hdd_sync`: the paper says random writes plus sync, the slides say
     O_DIRECT random reads.
   - `memcpy`: "1 GB" matches no single stress-ng option.
   - `socket`: `--udp`, `--udp-flood` or `--sock`?
   - `irq`: the timer frequency.
2. **What "cold" means.** Here, `drop_caches` before every run.
3. **What the containers ran in the lifecycle test, and whether stop waited
   for the workload.** Here it is the benchmark image, stopped 2 s after
   READY.
4. **When the stressors start relative to the container.** Here they start
   once the container is up (READY), and the 30 s warm-up comes after that.
5. **Whether runPHI also got `--cpuset-cpus`/`-m`.** Here it gets the same
   Docker options as runc. With the old runPHI, QEMU's non-vCPU threads
   therefore also ran on CPU 3. With the fixed runPHI they run on CPUs 0-2.
