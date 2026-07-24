# Context

Benchmark harness that measures **container boot time for real-time containers**,
from the moment the custom OCI runtime (`runphi`) is invoked to the moment the
container's first process runs.

Two ZCU104 boards, identical Buildroot images, both reachable as root over SSH:

| Host             | Role                                                    |
|------------------|---------------------------------------------------------|
| `192.168.100.52` | **Build board.** Has a native `gcc` on the target.       |
| `192.168.100.47` | **Target board.** No compiler. Runs the benchmark.       |

Userspace is busybox `ash`, not bash. cgroup **v1**. Docker is present on `.47`.

## How the measurement works

1. `rt_shim.c` is installed at `/usr/bin/runc`. Docker invokes it; it scans argv
   for `create`, takes `CLOCK_MONOTONIC`, appends `CREATE <id12> <ns>` to
   `/root/container_volume/times.txt`, then `execv`s `/usr/bin/runphi` with the
   same argv.
2. `booted.c` is the container's only process (no shell). It takes
   `CLOCK_MONOTONIC` as its very first action and appends
   `BOOTED <hostname> <ns>` to the same file via the bind mount.
3. Docker sets the container hostname to the first 12 chars of the container ID,
   so the two records join on that field. Pairing is by ID, not line order, so
   dropped or failed samples do not corrupt the rest.
4. `CLOCK_MONOTONIC` is the same timebase inside and outside the container
   because Docker does not use time namespaces. This assumption breaks for
   hypervisor-partitioned containers, which use a hardware counter via `devmem`
   instead.

## Files

- `rt_shim.c`     -> build as `runc`, install to `/usr/bin/runc` on `.47`
- `booted.c`      -> build as `booted`, install to `/root/container_volume/booted` on `.47`
- `boot_bench.sh` -> driver loop, runs on `.47`
- `analyze.sh`    -> pairs records and prints min/mean/median/p99/max/stddev

# Task: build on .52, deploy to .47

```sh
# 1. build (must be STATIC: booted runs inside an alpine/musl rootfs)
scp rt_shim.c booted.c root@192.168.100.52:/root/
ssh root@192.168.100.52 'cd /root && \
    gcc -O2 -static -o runc rt_shim.c && \
    gcc -O2 -static -o booted booted.c && \
    file runc booted'

# 2. verify both report "statically linked" before going further

# 3. pull artifacts, push to the target board (the password for both boards is "root")
scp root@192.168.100.52:/root/runc root@192.168.100.52:/root/booted .
scp runc booted boot_bench.sh analyze.sh root@192.168.100.47:/root/

# 4. place the container-side binary in the bind-mounted volume
ssh root@192.168.100.47 'mkdir -p /root/container_volume && \
    mv /root/booted /root/container_volume/booted && \
    chmod +x /root/container_volume/booted'
```

## Installing the shim: STOP AND ASK FIRST

Overwriting `/usr/bin/runc` on `.47` will break Docker on that board if the
binary is wrong (wrong arch, not static, `/usr/bin/runphi` missing). Do NOT do
this step unattended. When the user confirms:

```sh
ssh root@192.168.100.47 '
  [ -f /usr/bin/runc_vanilla ] || cp /usr/bin/runc /usr/bin/runc_vanilla
  cp /root/runc /usr/bin/runc && chmod +x /usr/bin/runc'
```

Smoke test immediately afterwards with a single throwaway container; if Docker
fails to start anything, restore `/usr/bin/runc_vanilla` over `/usr/bin/runc`.

## Preconditions to check on .47

- `stat -fc %T /sys/fs/cgroup` should print `tmpfs` (cgroup v1, as expected).
- `dockerd` must have been started with `--cpu-rt-runtime=950000`, otherwise the
  parent cgroup has no RT bandwidth to delegate and the per-container flag fails.
  Check the init script under `/etc/init.d/`.
- The `alpine` image must already be pulled for the board's architecture.
- `df -h /` before copying anything; the rootfs may be small or in RAM.

## Running

```sh
./boot_bench.sh -r 200 -c on      # cold-start: caches dropped each iteration
./boot_bench.sh -r 200 -c off     # warm-start
./analyze.sh /root/container_volume/times.txt
```

Discard the first iteration or two as warm-up.

## Style notes

- POSIX `sh` only in shell scripts. No bashisms: no `[[ ]]`, no arrays,
  no `for (( ))`, no `${var,,}`, no `$EPOCHREALTIME`.
- Keep expensive work (file open, path resolution, forks) out of the window
  between the timestamp and the runtime invocation. That is the whole point.
