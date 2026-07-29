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
`baseline` (idle root cell) plus the `fork8`, `memcpy8`, `open8`, `udp8` and
`cpu8` stressors.

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

Two further board preconditions, both of which reset on every reboot and neither
of which announces itself if you forget — `stressor.sh` checks both and warns:

- **Kernel cmdline must be `isolcpus=domain,managed_irq,3`.** See
  [Interference placement](#interference-placement).
- **Run `/root/max_perf.sh`.** cpufreq resets at boot and this kernel only has
  the `userspace` governor, so nothing restores the maximum clock by itself.

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

Progress and results:

```sh
R=/root/taclebench/results/APU_jailhouse/shmem
for d in $R/*_raw; do echo "$(basename $d): $(ls $d | wc -l)/52"; done
tail -20 $R/run.log       # ends with a per-configuration summary
ls $R/logs/               # per-configuration benchmark and stress-ng logs
```

A single configuration can be run on its own, and either script accepts `-b` to
restrict the benchmark set:

```sh
./external_script_shmem.sh -o $R/baseline_raw            # no stressor
./external_script_shmem.sh -b mpeg2 test3 -o /tmp/check
```

Results are written as `<config>_raw/results_<name>.bin.txt`, one line per
iteration.

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
unbootable.

> Reverting to `2-3` is needed before rerunning the **container boot-overhead**
> benchmarks on this board, which use `boot_bench.sh -p 2,3` and assume cores
> 2-3 are isolated. Backups: `/root/boot.scr.isolcpus2-3.bak` on the board and
> `boot_jailhouse.cmd.isolcpus2-3.bak` on the host.

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
| power cycle | `/tools/tapo/tapo_control.py zcu104a reset` (aliased `tapo`) |

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
