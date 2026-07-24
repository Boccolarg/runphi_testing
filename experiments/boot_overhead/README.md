# Boot-time overhead of runPHI forwarding

When a **standard** (non-partitioned) container is started, runPHI does not
manage it: it detects that the container is not runPHI-owned and forwards the
OCI call to the backed-up distro runc (`/usr/local/sbin/runc_vanilla`). That
forwarding inserts one extra process — runPHI — into the start path. This
experiment measures how much boot time that extra hop costs, and how the cost
changes between a **warm** page cache (runPHI binary already resident) and a
**cold** one (runPHI faulted in from disk).

## What is measured

Two metrics are supported; both compare a host-side or runtime-side timestamp
against the moment the container's init (`start.sh`) runs inside the container:

* **runc-level** (default): `t0 = the moment runc receives "create"`. Captured
  by `/usr/local/sbin/runc_listener`, a tiny wrapper docker invokes in place
  of the real runtime. The listener writes the timestamp + container id to
  a file, then `exec`s the real runtime with all original arguments. This
  excludes docker CLI + dockerd + containerd + shim startup from the
  measurement and matches the methodology of earlier runPHI experiments.
* **end-to-end** (`--end-to-end`): `t0 = host monotonic clock just before
  docker run`. Includes the whole docker stack startup. Matches what a user
  perceives as boot time, and is the simpler invariant to reason about.

In both modes the **terminal timestamp** is taken inside the container by the
probe (`start.sh`), reading the host kernel's monotonic clock from the
bind-mounted `/proc/timer_list` ("now at <ns> nsecs"). Containers share the
host kernel, so the in-container and host reads are the same clock. Reads are
done in pure bash (no `awk`/`sed`) so the measurement itself survives a
`drop_caches`.

The full path (docker CLI → dockerd → containerd → shim → runtime → container)
is identical across both arms **except** the runtime layer, so the difference
in mean boot time isolates the forwarding cost regardless of which `t0` you
chose:

| arm       | runc-level (listener) target     | end-to-end runtime |
|-----------|----------------------------------|--------------------|
| `vanilla` | listener → `runc_vanilla`        | `vanilla`          |
| `runphi`  | listener → runPHI → `runc_vanilla` | `runphi`         |

Crossed with cache policy:

| cache | behaviour                                            |
|-------|------------------------------------------------------|
| warm  | no cache flush; runPHI stays resident between runs   |
| cold  | `sync` + `drop_caches` before every iteration        |

```
overhead_warm = mean(runphi_warm) - mean(vanilla_warm)
overhead_cold = mean(runphi_cold) - mean(vanilla_cold)
```

The hypothesis is `overhead_cold > overhead_warm`: a warm cache keeps runPHI
and its shared libraries in memory, so the extra hop is nearly free, whereas a
cold cache pays disk I/O to load runPHI on every launch. (The container image
layers are evicted in both cold arms equally, so that cost cancels out of the
difference.)

## Prerequisites

1. runPHI installed as the drop-in runc via `switch_to_runphi.sh`, so the real
   runc is preserved at `/usr/local/sbin/runc_vanilla`.
2. The listener installed at `/usr/local/sbin/runc_listener`:

   ```sh
   install -m 0755 runc_listener /usr/local/sbin/runc_listener
   ```

3. Docker runtimes registered. Edit `/etc/docker/daemon.json`:

   ```json
   {
     "runtimes": {
       "runphi":           { "path": "/usr/bin/runc" },
       "vanilla":          { "path": "/usr/local/sbin/runc_vanilla" },
       "runphi_listened":  { "path": "/usr/local/sbin/runc_listener",
                             "runtimeArgs": ["/usr/bin/runc"] },
       "vanilla_listened": { "path": "/usr/local/sbin/runc_listener",
                             "runtimeArgs": ["/usr/local/sbin/runc_vanilla"] }
     }
   }
   ```

   `systemctl restart docker` and confirm:

   ```sh
   docker info --format '{{json .Runtimes}}'
   ```

   The plain `runphi`/`vanilla` runtimes are only needed for `--end-to-end`
   mode. The default (runc-level) mode only uses the `_listened` pair.
4. Run as **root** (cold cache writes `/proc/sys/vm/drop_caches`; the workload
   uses `--privileged` and `--cpu-rt-runtime`).

## Usage

Collection (bash) runs on the board; analysis (`analyze.py`) only needs
python3 with no extra packages. The two are decoupled so a minimal board that
can collect but not analyze (e.g. BusyBox `awk` without math) still works:
collect on the board, analyze on a workstation.

**Default (runc-level metric, via listener):**

```sh
sudo ./run_suite.sh -n 51
```

**End-to-end metric** (no listener; matches what `time docker run …` measures):

```sh
sudo ./run_suite.sh --end-to-end -n 51
```

**Collect-only** (board too minimal to run python3; analyze on a workstation):

```sh
sudo ./run_suite.sh --collect-only -n 51       # on the board
SSHPASS=root ./analyze_remote.sh root@192.168.100.47 \
    /root/boot_overhead/results/<timestamp> -- --warmup 1
```

`analyze_remote.sh` uses `scp -O` (legacy protocol) because minimal boards
typically lack an `sftp-server`. You can also copy the results dir by any means
and run `analyze.py --dir <dir>` directly.

Other forms:

```sh
# Warm-only, no root, no rt-cgroup requirement:
./run_suite.sh --warm-only -n 51 -- --no-cpu-rt

# Re-run a single condition, then analyze that pair (with the listener file
# from this condition):
sudo ./boot_overhead.sh --runtime runphi_listened --drop-caches -l runphi_cold \
    -n 51 -o ./results/manual --listener-file /tmp/runc_listener_create.txt
./analyze.py --pair ./results/manual/runphi_cold_launch.txt \
             ./results/manual/runphi_cold_times.txt \
             --create ./results/manual/runphi_cold_create.txt \
             -l runphi_cold --warmup 1
```

Pass-through options after `--` (on `run_suite.sh`) go to `boot_overhead.sh`
(`--image`, `--volume`, `--no-cpu-rt`, `--run-seconds`, …).

## Output

`run_suite.sh` writes a timestamped directory under `./results/` containing,
per condition, `<label>_launch.txt` (host) and `<label>_times.txt`
(container). `analyze.py --dir <that dir>` prints a table like:

```
==================== Boot-time summary (ms) ====================
vanilla_warm   n=50  mean=412.310 median=410.2 sd=8.1 min=401 p95=428 max=433
runphi_warm    n=50  mean=415.880 median=414.0 sd=8.4 min=404 p95=431 max=438
vanilla_cold   n=50  mean=690.4   median=688.1 sd=22  min=651 p95=731 max=744
runphi_cold    n=50  mean=712.9   median=710.5 sd=24  min=669 p95=758 max=771
----------------------------------------------------------------
Forwarding overhead (warm cache): +3.570 ms
Forwarding overhead (cold cache): +22.500 ms
================================================================
```

(Numbers above are illustrative.)

## Files

| file                | role                                                          | runs on     |
|---------------------|---------------------------------------------------------------|-------------|
| `start.sh`          | in-container probe; records the boot timestamp                | container   |
| `runc_listener`     | OCI-runtime wrapper; captures t0 on `create`, execs target    | board (runtime) |
| `boot_overhead.sh`  | drives one condition (one runtime × one cache policy)         | board       |
| `run_suite.sh`      | sweeps the 2×2 matrix, collects raw data, optional analysis   | board       |
| `analyze.py`        | pairs launch / times / create files, prints stats + overhead  | board or PC |
| `analyze_remote.sh` | pulls a board results dir via `scp -O` and analyzes locally   | workstation |

Collection (`start.sh`, `boot_overhead.sh`, `run_suite.sh`) is pure bash and
needs no math tools. Analysis (`analyze.py`) needs only python3. They are
deliberately split so a minimal board can collect even when it cannot analyze.

## Caveats

- The first iteration is discarded by default (`--warmup 1`) to drop
  process-pool / JIT-of-the-pipeline cold-start noise unrelated to runPHI.
- Arms are not paired iteration-by-iteration (different containers), so the
  overhead is a difference of means, reported alongside each arm's stddev.
- The end-to-end metric includes the cost of *spawning* the extra process
  (fork/exec, dynamic linker, page faults), which is the real-world overhead —
  not just runPHI's internal wall time. For a finer breakdown you could also
  read runPHI's own `logging::timer` phase logs.
