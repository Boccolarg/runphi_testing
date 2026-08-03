# TACLeBench on a Jailhouse bare-metal APU cell (ZynqMP)

Measures the execution time of the TACLeBench suite running **bare metal in a
Jailhouse non-root cell** on a Cortex-A53, while `stress-ng` generates
interference from the **root cell** (Linux) on the remaining cores. The point is
to quantify how much a co-located Linux workload perturbs an isolated bare-metal
partition.

Currently targets the **ZCU104** (`zcu104a`, `192.168.100.47`, root/root). It was
originally built for a Kria KV260; both boards carry the same ZynqMP SoC, so the
port was mostly a matter of addresses and paths. The KV260 results live in
`~/Documenti/Lavoro/taclebench/taclebench_journal/ZIC-Jailhouse/`.

Each benchmark runs 31 times per configuration, under six configurations:
`baseline` (idle root cell) plus the `fork4`, `memcpy4`, `open4`, `udp4` and
`cpu4` stressors. One configuration takes about an hour, so a full campaign is
roughly six.

> [!IMPORTANT]
> Two root-Linux behaviours will hang this board mid-campaign until they are
> disabled, and neither is obvious from the symptom. Read
> [The two deadlocks](#the-two-deadlocks--read-this-before-running) before your
> first run. `stressor.sh` handles both, but only if you let it.

## How the measurement works

The inmate times *itself*. Wrapping the hypervisor's own accounting or the root
cell's clock around the run would measure cell setup and teardown too, so
instead each benchmark is linked against a generated wrapper that reads the
ZynqMP system counter directly, and hands the two timestamps to the root cell
through a one-word shared memory mailbox:

```
root cell (external_script_shmem.sh)      inmate (<name>_wrapper.c)
------------------------------------      -------------------------
write INITIAL (0xDEADBEEF)
create / load / start cell
                                          map counter + mailbox uncached
                                          read counter -> start_time
                                          write start_time to mailbox
see mailbox != INITIAL -> record start
write INTERMEDIATE (0xBEEFDEAD)
                                          run <name>_entry()
                                          read counter -> end_time
                                          spin until mailbox == INTERMEDIATE
                                          write end_time to mailbox
see mailbox != INTERMEDIATE -> record end
destroy cell
```

`end_time` is sampled **before** the inmate waits for the acknowledgement, so
the handshake latency is not part of the measurement. The root cell polls every
0.5 s; that granularity affects only how long the run takes, never the numbers.

Addresses, which must agree between the wrapper and the cell configuration:

| | address | notes |
|---|---|---|
| system counter | `0xFF250000` | read aperture, free-running, **100 MHz** (measured 99.9996 MHz) |
| shared mailbox | `0x3AD00000` | one 32-bit word, `ROOTSHARED` |
| inmate RAM | `0x3AE00000` | mapped at virt 0, 32 MB, loadable |

> The counter is read as a **32-bit** value, so it wraps every ~42.9 s. The
> analysis script handles a single wrap; nothing in the suite runs longer than
> 0.6 s, so this only ever affects samples that straddle a wrap.

## Layout

```
kernel/ sequential/ app/ test/   TACLeBench sources, one directory per benchmark
benchmark_used.txt               drives the build: an upper-case directory name
                                 followed by the benchmarks it contains
compile_benchmark_wrap.sh        builds every benchmark into a raw inmate binary
external_script_shmem.sh         runs the suite on the board, one configuration
stressor.sh                      drives all six configurations back to back
compiler_types.h  config.h       force-included by the build
executables_shm/bin/             output: <name>.bin, ready to `jailhouse cell load`
executables_shm/obj/             intermediate objects, linked ELFs, repacked lib
```

The benchmark sources are **already converted**: each `main()` has been renamed
to `<name>_entry()` so the wrapper can supply `inmate_main()`. The build re-runs
that rename, which is a no-op on converted sources.

## Prerequisites

**Host** — an `aarch64-linux-gnu-*` toolchain and a built Jailhouse tree
providing the inmate library, headers and linker script. The default is

```
/home/boccolarg/runphi/environment_builder/environment/zcu104/jailhouse/build/jailhouse
```

override with `JAILHOUSE_BUILD=... ./compile_benchmark_wrap.sh`.

**Board** — Jailhouse enabled with the Omnivisor root cell:

```sh
. /etc/profile.d/jailhouse_path.sh
./scripts_jailhouse_zcu104/jailhouse_setup/jailhouse_start.sh   # no arguments
jailhouse cell list                                             # expect ZynqMP-ZCU104, CPUs 0-3
```

Do **not** pass `-c`/`--col`. The cache-colouring root cells leave part of root
Linux's RAM read-only in stage-2; processes then start dying inside `execve` and
`ssh` stops working while the network stays up.

Further board preconditions. None of them announces itself if you forget, and
the ones that reset at boot have to be redone every time — `stressor.sh` handles
or warns about each:

| precondition | survives reboot? | why |
|---|---|---|
| cmdline `isolcpus=domain,managed_irq,3` | yes | so stressors reach all three root CPUs — see [Interference placement](#interference-placement) |
| cmdline `rcutree.kthread_prio=1` | yes | so the RCU kthread cannot be starved — see [the deadlocks](#the-two-deadlocks--read-this-before-running) |
| `/root/max_perf.sh` | **no** | cpufreq resets at boot and this kernel has only the `userspace` governor |
| unbind `cortex_edac` | **no** | its 100 ms per-CPU IPI poll deadlocks against Jailhouse CPU handover |

## Build

```sh
./compile_benchmark_wrap.sh                       # all of benchmark_used.txt
./compile_benchmark_wrap.sh -b binarysearch fac   # just these
```

Produces `executables_shm/bin/<name>.bin`: raw AArch64 binaries, linked at
address 0 with the entry point at offset 0, matching the cell's `virt_start = 0`
RAM region. A report lands in `compilation_report.txt` and compiler diagnostics
in `compilation_errors.log`.

Benchmarks are compiled at **`-O0`, deliberately** — the experiment measures
unoptimised code, and an earlier optimised run is kept separately as
`ZIC-Jailhouse(NON-O0)` in the journal. Do not raise it.

## Deploy

```sh
BOARD=root@192.168.100.47
ssh $BOARD 'mkdir -p /root/taclebench/{executables,results}/APU_jailhouse/shmem \
                     /root/taclebench/workdirs/APU_jailhouse'
scp -O executables_shm/bin/*.bin $BOARD:/root/taclebench/executables/APU_jailhouse/shmem/
scp -O external_script_shmem.sh stressor.sh $BOARD:/root/taclebench/workdirs/APU_jailhouse/
ssh $BOARD 'chmod +x /root/taclebench/workdirs/APU_jailhouse/*.sh'
```

`scp` needs `-O`: the board has no `sftp-server`.

## Run

The full campaign takes about **six hours** (roughly one hour per
configuration), so run it detached:

```sh
ssh root@192.168.100.47
screen -dmS taclebench bash -c '. /etc/profile.d/jailhouse_path.sh; \
  /root/taclebench/workdirs/APU_jailhouse/stressor.sh 2>&1 \
  | tee /root/taclebench/results/APU_jailhouse/shmem/run.log; \
  echo "=== RUN FINISHED ==="; exec bash'

screen -r taclebench     # live output; ctrl-a d to detach
```

Progress and results. Count *lines*, not files: a result file exists as soon as
a benchmark starts, so counting files overstates progress.

```sh
R=/root/taclebench/results/APU_jailhouse/shmem
for d in $R/*_raw; do
  full=0; for f in "$d"/results_*.txt; do [ "$(wc -l < $f)" -eq 31 ] && full=$((full+1)); done
  echo "$(basename $d): $full/52"
done
tail -20 $R/run.log       # ends with a per-configuration summary
ls $R/logs/               # per-configuration benchmark and stress-ng logs
cat $R/*_raw/DROPPED.txt  # benchmarks abandoned under a stressor, if any
```

## The two deadlocks — read this before running

Three campaigns died mid-run before these were understood (2026-07-29 and
2026-07-30, twice). **The board is not flaky.** Both failures are root Linux
deadlocking against Jailhouse's CPU handover, and both look like "the board
crashed" while it is in fact still powered, still printing, and sometimes still
answering ssh.

`jailhouse cell create` and `destroy` hotplug the inmate's CPU — you can see it
on the console as `psci: CPU3 killed` and `CPU3: Booted secondary processor`.
Anything in root Linux that (a) IPIs that CPU or (b) blocks CPU hotplug will
therefore deadlock, thousands of times per campaign.

### 1. `cortex_edac` — an IPI to a CPU that Jailhouse took

`cortex_edac`, which the kernel itself reports as deprecated
(`cortex_edac edac: cortex l1/l2 driver is deprecated`), registers a **polled**
EDAC device for per-CPU L1/L2 cache ECC with `poll_msec=100`. Reading those
registers requires executing on the target CPU, so every poll issues an
`smp_call_function_any()` IPI and waits for completion. Ten times a second.

When such an IPI targets **CPU 3 just as Jailhouse takes it**, the completion
never arrives. The `edac-poller` kworker wedges forever, RCU grace periods stop
advancing, and the board dies:

```
rcu: INFO: rcu_sched self-detected stall on CPU
Workqueue: edac-poller edac_device_workq_function
 smp_call_function_single+0xac/0x160
 smp_call_function_any+0x58/0x100
 cortex_arm64_edac_check+0x140/0x150
```

The stall repeats every ~63 s with a growing tick count, `sync` blocks, and even
`reboot -f` will not complete — the board needs a power cycle.

`stressor.sh` unbinds the driver automatically. To do it by hand:

```sh
echo edac > /sys/bus/platform/drivers/cortex_edac/unbind
```

This costs only L1/L2 ECC error *reporting*, affects no measurement, and a
reboot restores it — so **it must be redone after every boot**, like
`max_perf.sh`. Verify with `ls /sys/devices/system/edac/` — `cpu_cache` should be
absent, leaving only the interrupt-driven `zynqmp_ocm` (`poll_msec=0`, no IPI).

Anything else in root Linux that polls per-CPU registers by IPI is a candidate
for the same deadlock. `zynqmp_ocm` is safe because it is interrupt-driven.

### 2. RCU starvation — CPU hotplug that can never complete

CPU hotplug calls `synchronize_rcu()`, so `jailhouse cell create` cannot return
until an RCU grace period completes. With the default `rcutree.kthread_prio=0`
the RCU grace-period kthread is an ordinary `SCHED_OTHER` task, and enough
runnable stressor workers on only three root CPUs simply never let it run. Once
it falls behind, the next `jailhouse` call blocks indefinitely — and because the
stressors keep running, it never recovers.

Unlike the EDAC case there is **no stall trace and no panic**. The console shows
only starvation notices, and the machine stays up:

```
rcu: INFO: rcu_preempt detected expedited stalls / kthread starved
rcu: RCU grace-period kthread stack dump:
task:rcu_sched       state:R   ...  rcu_gp_fqs_loop+0xe8/0x374
rcu: Stack dump where RCU GP kthread last ran:
task:stress-ng-memcp state:R  running task
```

The tell is a **single benchmark making no progress for hours** while its
neighbours were fine. It cost ~9h50m on `bitcount` under `fork8` and ~2h18m on
`gsm_enc` under `memcpy8` — different benchmarks each time, because it is not the
benchmark. Meanwhile sshd may be too starved to complete a banner exchange, which
reads exactly like a dead board.

Three changes together fix it, and all three matter:

| change | where | effect |
|---|---|---|
| `rcutree.kthread_prio=1` | kernel cmdline | `rcu_sched` becomes `SCHED_FIFO` prio 1 and cannot be starved |
| `nice -n 19` on stress-ng | `stressor.sh` | stressors still pin every core but yield to kernel threads |
| 4 workers, not 8 | `stressor.sh` | fewer runnable hogs competing with the harness |

Verify after boot:

```sh
cat /sys/module/rcutree/parameters/kthread_prio   # want 1
chrt -p 12                                        # rcu_sched: want SCHED_FIFO
```

Measured effect: `fork8` took **10h54m** and never finished; `fork4` niced with
RCU prioritised runs at 71 s/benchmark, i.e. **61 min**, the same as an idle
baseline. Per-iteration cost is 2.3 s stressed and 2.3 s unstressed — the
stressors no longer slow the harness at all.

`nice` does not weaken the interference. Measured over 5 s with 4 memcpy workers,
CPUs 0-2 were at 100% utilisation both niced (501/501/502 busy ticks) and
un-niced (503/503/503). Three saturated cores is the ceiling either way, which is
also why 4 workers interfere as much as 8.

### Backstops, if it wedges anyway

Neither fix is a proof, so the harness no longer trusts the kernel:

- Every `jailhouse` call and `sync`/`drop_caches` runs under a 60 s cap
  (`run_bounded` in `external_script_shmem.sh`; busybox has no `timeout(1)`).
- Each benchmark gets `BENCH_TIME_CAP` (20 min; healthy is ~70 s). Over that it
  is **dropped**: partial data deleted, name appended to `<config>_raw/DROPPED.txt`,
  and the run moves on. `--resume` will not retry a dropped benchmark.
- Always check `cat $R/*_raw/DROPPED.txt` before trusting a configuration, and
  report anything listed there — a dropped benchmark is missing data, not a
  measurement.

### Resuming after a crash

Both scripts take `-r`/`--resume`, which makes the campaign restartable:

```sh
stressor.sh --resume        # same launch line as above, plus --resume
```

It skips configurations whose `<config>_raw` already holds a full result file
for every binary, and within a configuration skips benchmarks that already have
all 31 iterations. A **partial** file — what an interrupted benchmark leaves
behind — is redone from scratch rather than appended to, so a single result file
never mixes two machine states. A crash therefore costs at most one benchmark.

Because the board leaves no crash evidence of its own (`/var/log` does not
survive a reboot and `pstore`/`ramoops` are not configured — the kernel reports
`mtdoops: mtd device must be supplied`), capture the console on the lab console
host for the duration of a long run:

```sh
ssh -p 19500 root@192.168.100.45
stty -F /dev/zcu104a-01 115200 raw -echo
setsid sh -c 'exec cat /dev/zcu104a-01 >> /tmp/zcu104a_run.log 2>&1' < /dev/null &
```

> [!WARNING]
> That capture holds the tty **exclusively**. Attaching `picocom` while it runs
> shows you nothing, which is easily mistaken for a dead board. Kill it first:
> `pkill -f "cat /dev/zcu104a-01"`.

An unclean shutdown is confirmed after the fact by `EXT4-fs (mmcblk0p2):
recovery complete` in `dmesg` on the following boot. A *starved* board leaves no
such trace, because it never actually went down.

### Is it dead, or just starved?

These look identical from a frozen shell, and the distinction decides whether you
power-cycle. From the console host:

```sh
L=$(ls -t /tmp/zcu104a_*.log | head -1)
stat -c%y "$L"                                    # still being written = kernel alive
grep -c "self-detected stall\|Kernel panic" "$L"  # >0 = a real deadlock
grep -c "sufficient CPU time" "$L"                # >0 = starvation only
```

A starved board recovers once the stressors are killed, but the kill has to
survive your own session dying:

```sh
ssh root@192.168.100.47 'nohup sh -c "screen -S taclebench -X quit; sleep 1; pkill -KILL stress-ng" >/dev/null 2>&1 &'
```

If it is genuinely wedged, `sync` and `reboot -f` both hang and only a power
cycle works — see [Board reference](#board-reference).

### Subsets

`-c` runs chosen configurations, `-b` restricts the benchmark set:

```sh
./stressor.sh --resume -c "open4 udp4"                   # two configurations
./external_script_shmem.sh -b mpeg2 test3 -o /tmp/check   # ad-hoc, no stressor
```

Results are written as `<config>_raw/results_<name>.bin.txt`, one line per
iteration.

### Never collect unstressed data by accident

`stressor.sh` passes `--require-pid` to the bench script, which checks before
every iteration that the stressor is still alive and aborts with exit 3 if it is
not. Without that check a dead stressor is invisible: the benchmarks keep running
and get filed as stressed.

This is not hypothetical. `STRESS_TIMEOUT` used to be 10h; the `fork8`
configuration ran 10h54m, `stress-ng` exited cleanly at exactly 36000 s, and
**46 of 52 benchmarks were recorded as stressed with nothing stressing them**.
File mtimes gave it away: six done in the first eight minutes, a ten-hour gap,
then forty-six in fifty-four minutes starting twenty seconds after the stressor
died. `STRESS_TIMEOUT` is now 72h and is only a leak guard, since each
configuration kills its own stressor.

Worth knowing: on this platform valid stressed data sits at 0.98–1.01x baseline
anyway — a cell on a dedicated core is largely interference-immune — so
contaminated data is statistically almost indistinguishable from good data. It
has to be prevented by mechanism, not spotted in the numbers.

## Analysis

`extract_time.sh` (in the journal directory alongside the results) converts
every `*_raw` directory into a sibling directory of per-benchmark times in
seconds, handling counter wraparound:

```sh
scp -O -r root@192.168.100.47:/root/taclebench/results/APU_jailhouse/shmem/\*_raw <dest>
cd <dest> && ./extract_time.sh
```

Its `frequency=100000000` matches this board. Its wraparound branch computes
`stop + (0xFFFFFFFF - start)` where the exact value is
`stop + (0x100000000 - start)`, so wrapped samples read one tick (10 ns) short —
about 1e-8 relative on the only benchmark that wraps with any regularity.

## Interference placement

`stress-ng` must load the three root-cell CPUs while the inmate owns CPU 3, so
that the interference matches the original KV260 arrangement.

This requires the kernel cmdline `isolcpus=domain,managed_irq,3`. The board
previously used `2-3`, and **an affinity mask is not a substitute**:
`isolcpus=domain` removes a CPU from every scheduling domain, so a mask of
`{0,1,2}` never gets balanced onto CPU 2 — measured as literally zero ticks
there under a saturating load. Only exclusive pinning to `{2}` reaches it, and
the board has no `taskset` (busybox has no such applet); `sched_setaffinity`
does work, e.g.

```sh
python3 -c "import os,sys; os.sched_setaffinity(0,{2}); os.execvp(sys.argv[1],sys.argv[1:])" cmd ...
```

The cmdline lives in `/boot/firmware/boot.scr`, a U-Boot script image. To change
it, edit `boot_sources/boot_jailhouse.cmd` in the environment builder and
regenerate:

```sh
mkimage -A arm64 -O linux -T script -C gzip -a 0 -e 0 -n "" \
        -d boot_jailhouse.cmd boot.scr
```

then on the board `mount -o remount,rw /boot/firmware`, copy it in, `sync`, and
remount `ro` — the FAT partition must not be left writable, as an unclean
shutdown can corrupt `BOOT.BIN`/`Image`/`boot.scr` and leave the board
unbootable. Verify what actually got installed, since a silent failure here is
easy to miss:

```sh
dd if=/boot/firmware/boot.scr bs=1 skip=72 2>/dev/null | grep -o 'isolcpus=[^"]*'
cat /proc/cmdline        # after the reboot
```

The current cmdline is
`isolcpus=domain,managed_irq,3 rcutree.kthread_prio=1 skew_tick=1 deferred_probe_timeout=1 ...`.

> Reverting to `2-3` is needed before rerunning the **container boot-overhead**
> benchmarks on this board, which use `boot_bench.sh -p 2,3` and assume cores
> 2-3 are isolated. Backups: `/root/boot.scr.isolcpus2-3.bak` on the board, and
> `boot_jailhouse.cmd.isolcpus2-3.bak` / `.pre-rcuprio.bak` on the host.

### Worker count: 4, not the KV260's 8

`CONFIGS` uses four workers per stressor. Three saturated cores is the ceiling on
interference, so 4 workers load them exactly as thoroughly as 8 (measured: 100%
on CPUs 0-2 either way), while 8 runnable hogs were enough to starve RCU and
wedge the campaign for hours at a time.

The configuration directories are named for what was actually run — `fork4_raw`,
`memcpy4_raw` and so on — so the data is self-labelling and cannot be silently
compared against the KV260's 8-worker columns. **Record this deviation in any
writeup.**

## Board reference

The inmate cell is defined in the environment builder, not here:
`environment/zcu104/jailhouse/custom_build/jailhouse/configs/arm64/zynqmp-zcu104-APU-inmate-demo.c`

| | |
|---|---|
| cell name | `inmate-demo-APU` |
| CPU | 3, held out of Linux by `isolcpus` |
| memory regions | UART1 `0xff010000`, system counter `0xff250000`, SHM `0x3ad00000`, RAM `0x3ae00000` (virt 0, 32 MB), comm region virt `0x80000000` |
| ivshmem | none — the legacy `zynqmp-zcu104-inmate-demo.cell` declares one that collides with the root cell's first endpoint and fails `cell create` with `-EBUSY`. Use the APU cell. |

RAM and SHM sit inside the `rproc@3ad00000` `no-map` reservation of
`system_jailhouse.dts`, so Linux never maps those pages — but `devmem` still
reaches the mailbox, which is what the handshake relies on.

Validate a configuration offline before touching the board:

```sh
jailhouse config check ${JAILHOUSE_DIR}/configs/arm64/zynqmp-zcu104-omnv.cell \
                       ${JAILHOUSE_DIR}/configs/arm64/zynqmp-zcu104-APU-inmate-demo.cell
```

**Consoles and recovery** — via the lab console host, `192.168.100.45` port 19500:

| | |
|---|---|
| `/dev/zcu104a-01` | Linux console + Jailhouse hypervisor log (UART0) |
| `/dev/zcu104a-02` | **inmate cell console** (UART1) |
| power cycle | `/tools/tapo/tapo_control.py zcu104a reset` (aliased `tapo`) — see below |

The power cycle needs Tapo credentials that live in the console host's
`.bashrc`, which a non-interactive ssh does not source, so `tapo` alone fails
with "Please set TAPO_USERNAME and TAPO_PASSWORD":

```sh
ssh -p 19500 root@192.168.100.45 'bash -s' <<'EOF'
eval "$(grep -E '^[[:space:]]*(export[[:space:]]+)?TAPO_(USERNAME|PASSWORD|P300_IPS)=' /root/.bashrc)"
export TAPO_USERNAME TAPO_PASSWORD TAPO_P300_IPS
/tools/tapo/tapo_control.py zcu104a reset
EOF
```

A power cycle re-enumerates the USB serial bridge, so any console capture dies
with it and must be restarted afterwards.

`picocom -b 115200 /dev/zcu104a-02` to watch the inmate. Note that
`jailhouse console -f` shows the *hypervisor's* log, not the inmate's. The
wrapper emits no console output at all, so UART1 stays silent through a healthy
run — it is where a crashing inmate would surface, and where to add a `printk`
when debugging one.

## Benchmark set

`benchmark_used.txt` lists **52** benchmarks. **49** of them are the mandatory
set that appears in `plots/interference_matrix.png`; the extra three are `sha`,
`rijndael_dec` and `rijndael_enc`, which were excluded from that figure because
they would not run under rt-Linux, not because of anything on the Jailhouse
side. All 52 build and run here.

`Benchmark-non-eseguiti.txt` is a historical record of benchmarks that failed on
the KV260 (`rijndael_*`, `sha`, `filterbank`, `huff_dec`, `huff_enc`). It is
**out of date** for the first three, which now work. `filterbank`, `huff_dec`,
`huff_enc`, `susan` and `complex_updates` still have sources in the tree but are
not in `benchmark_used.txt` and have never been part of the results.

No benchmark has had to be dropped under any stressor on the ZCU104. If that
changes, the drop is recorded in `<config>_raw/DROPPED.txt` rather than left
implicit — check it before trusting a configuration.

### Discarded data on the board

Quarantined directories deliberately do **not** end in `_raw`, so
`extract_time.sh` ignores them:

| directory | why |
|---|---|
| `fork8_raw.INVALID-stressor-timed-out` | 46 of 52 measured with no stressor running (the 10h `STRESS_TIMEOUT`) |
| `memcpy8_raw.SUPERSEDED-8workers` | 24/52 collected at 8 workers; not mixable with 4-worker data |

`baseline_raw` predates the harness changes and remains valid: it was collected
with no stressor, and the bounded-operation and drop logic are no-ops when
nothing hangs.

## Gotchas

- **Thin archive.** The Jailhouse inmate `lib.a` is a *thin* archive whose
  members are recorded as `/home/environment/...`, paths inside the build
  container. That container no longer exists, so `compile_benchmark_wrap.sh`
  parses the archive, rewrites the prefix and repacks the members into a regular
  archive before linking. If the build tree moves, adjust `CONTAINER_PREFIX` and
  `HOST_PREFIX` at the top of the script.
- **`main()` renaming.** The build's `sed` only matches `int main(void)`
  exactly. A benchmark declaring `main` differently needs renaming by hand; the
  script now detects this and reports it rather than failing at link time with a
  missing `<name>_entry`.
- **Never run the `*_gic*` scripts against these sources.** They generate a
  differently named entry point and you get `multiple definition of
  benchmark_entry`. Restore pristine TACLeBench sources before switching.
- **`map_range` is required.** The wrapper must map both MMIO pages
  `MAP_UNCACHED` before touching them. Omitting this was the original reason the
  shared memory approach appeared not to work at all.
- **The board's busybox lacks `timeout`, `pgrep` and `taskset`.** All three are
  reflexes worth unlearning here, and each fails differently: `timeout` and
  `pgrep` give "not found" (a `while pgrep ...` guard silently becomes *false*,
  so whatever it was protecting runs immediately), while `taskset` is simply
  absent as an applet. Use `run_bounded`, `ps w | grep "[s]omething"`, and
  `python3 -c "import os,sys; os.sched_setaffinity(...)"` instead.
- **`ls | wc -l` is unreliable on the dev host** — `ls` is aliased to `eza`,
  which emits a header when piped. Use `find ... | wc -l`. Likewise `cd` is
  aliased to `zoxide`, which is not on a non-interactive `PATH`.
- **Counting finished benchmarks means counting lines.** A result file is created
  when a benchmark *starts*, so `ls | wc -l` reports work that may not exist.
  Compare `wc -l` against `ITERATIONS`.

## Legacy

An earlier variant reported timings over UART using the GIC timer instead of
shared memory. It was superseded — parsing serial output is far more fragile
than reading a word of memory — but is kept for reference:
`gic_compile_benchmark.sh`, `external_script_gic.sh`,
`external_script_exclude_gic.sh`, `script45_gic.sh`, and the prebuilt KV260
binaries in `executables_gic/`. `spiegazione.txt` holds the original Italian
build notes, now superseded by this file.

`lscript.ld` is a Xilinx/Vitis linker script referenced by nothing — the build
uses Jailhouse's `inmate.lds`. The copies of `inmate.h`, `inmate_common.h`,
`inmate_little.h`, `uart.h`, `string.h`, `test.h` and `stdarg_jailhouse.h` in
this directory are likewise unused: the build includes the real ones out of the
Jailhouse tree. `config.h` and `compiler_types.h`, by contrast, *are* used —
both are force-included on every compilation.
