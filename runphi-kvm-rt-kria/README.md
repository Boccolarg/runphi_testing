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

The students' own scripts were not available, so the method is
reconstructed from the paper and the slides. Every guess is listed in
[Assumptions](#assumptions-reconstructed-from-the-paper).

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
fix"` adds a before/after comparison of runPHI-KVM.

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

| | |
|---|---|
| Progress | `cat /root/rtbench/state/done`; `tail /root/rtbench/logs/orchestrate.log /root/rtbench/logs/<campaign>.log` |
| Stop after the current campaign | `rm /root/rtbench/state/ENABLED` (the watchdog then exits too) |
| Stop now | `rm /root/rtbench/state/ENABLED`, then `pkill -f orchestrate.sh; pkill -f rtbench.py`, then `python3 /root/rtbench/bench/rtbench.py check` and clean up the `rtb-*` containers |
| Results | `/root/rtbench/results/<campaign>/runs.jsonl` and `run_NN/`; copied to `/root/rtbench-kv260` on the server when the queue finishes |

## Assumptions (reconstructed from the paper)

Points the paper and slides leave open, worth confirming with the students:

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
