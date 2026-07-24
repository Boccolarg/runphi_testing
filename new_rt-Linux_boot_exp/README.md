# Real-Time Container Boot-Time Benchmark — Runbook

This harness measures **how long a real-time container takes to boot** on a ZCU104
board: from the moment the OCI runtime (`runphi`) is invoked, to the moment the
container's first (and only) process actually runs.

> This README is the *practical* runbook — it documents what actually works on
> these boards, including the workarounds we had to discover. Where it differs
> from `CLAUDE.md`, **follow this file**; the differences are called out in
> [Deviations & gotchas](#deviations--gotchas). Read that section before you
> assume anything, especially after a reboot.

---

## TL;DR cheat sheet

Run from the **dev host** (this x86_64 machine). The board's SSH password is `root`.

```sh
# helpers (paste once per shell)
SSH="sshpass -p root ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no"
SCP="sshpass -p root scp -O -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no"

# 1. BUILD (static aarch64, cross-compiled locally — see Deviations)
aarch64-linux-gnu-gcc -O2 -static -o runc   rt_shim.c
aarch64-linux-gnu-gcc -O2 -static -o booted booted.c
file runc booted            # both must say: ARM aarch64 ... statically linked

# 2. DEPLOY to the target board .47
$SCP runc booted boot_bench.sh analyze.sh root@192.168.100.47:/root/
$SSH root@192.168.100.47 'mkdir -p /root/container_volume && \
    mv /root/booted /root/container_volume/booted && \
    chmod +x /root/container_volume/booted /root/runc /root/boot_bench.sh /root/analyze.sh'

# 3. CHECK preconditions (see Step 3) — fix any that fail (Step 4)

# 4. INSTALL the shim (destructive — see Step 5 for the safe version w/ smoke test)
$SSH root@192.168.100.47 'cp /usr/bin/runc /usr/bin/runc.pre_shim_bak && \
    cp /root/runc /usr/bin/runc && chmod +x /usr/bin/runc'

# 5. RUN + ANALYZE (on the board)
$SSH root@192.168.100.47 'cd /root && : > /root/container_volume/times.txt && \
    ./boot_bench.sh -r 200 -c on && ./analyze.sh /root/container_volume/times.txt'
```

---

## Machines

| Machine | Role |
|---------|------|
| **dev host** (this x86_64 machine) | Cross-compiles the binaries with `aarch64-linux-gnu-gcc`. |
| `192.168.100.47` (`zcu104a`) | ZCU104 target board. Buildroot, busybox `ash`, cgroup **v1**, Docker. Runs the benchmark. Root over SSH, password `root`. |

The target board has no usable native compiler, so we build on the dev host and
copy the (static) binaries over.

---

## What is being measured, and how

Boot time = `T_booted − T_created`, both taken from `CLOCK_MONOTONIC`.

1. **`rt_shim.c`** is installed as `/usr/bin/runc` (Docker's default OCI runtime).
   When Docker invokes it, the shim scans argv for `create`; the instant it sees
   it, it takes `CLOCK_MONOTONIC` (**T0**), appends `CREATE <id12> <ns>` to
   `/root/container_volume/times.txt`, then `execv`s the real runtime
   `/usr/bin/runphi` with the same argv. The log file is opened *before* the
   timestamp so only a single `write()` sits inside the measured window.

2. **`booted.c`** is the container's only process (no shell). Its very first
   action is `CLOCK_MONOTONIC` (**T1**); it then appends
   `BOOTED <hostname> <ns>` to the *same* file through the bind mount
   (`/root/container_volume` → `/home` inside the container, so it writes
   `/home/times.txt`).

3. Docker sets the container hostname to the first 12 chars of the container ID.
   The shim logs those same 12 chars as `<id12>`. **`analyze.sh` joins the two
   records by that ID**, not by line order — so a dropped or failed sample never
   corrupts the rest. A `CREATE` with no matching `BOOTED` (e.g. a non-benchmark
   container) is simply ignored.

4. `CLOCK_MONOTONIC` is the same timebase inside and outside the container
   because Docker does **not** use a time namespace. (This assumption would break
   for hypervisor-partitioned containers, which read a hardware counter via
   `devmem` — not the case here.)

5. **Optional `START` timestamp (experiment).** containerd invokes the runtime
   separately for `create` then `start`. If the marker file `/run/rt_measure_start`
   exists, the shim *also* logs `START <id12> <ns>` when the OCI `start` arrives —
   splitting the boot into **create→start** (runtime/setup) and **start→booted**
   (process launch). It is opt-in (`boot_bench.sh -s on`, which touches/removes the
   marker) because `start` sits *inside* the create→booted window, so the extra
   `open+write` slightly inflates the baseline. With the marker absent the only
   added cost is one `access()` per start, and `analyze.sh`/`extract_boot_ms.sh`
   ignore `START` lines, so `-s off` runs are byte-for-byte the old behavior.

### The runtime chain after the shim is installed

```
docker run ...
   └─ /usr/bin/runc        ← rt_shim  (logs CREATE, then execs runphi)
        └─ /usr/bin/runphi  ← real RT runtime
             ├─ RT container      → runphi handles it itself
             └─ standard container → redirects to /usr/local/sbin/runc_vanilla
```

`boot_bench.sh` does **not** pass `--runtime`, so it uses Docker's default
(`runc`) = the shim. That is the whole point.

---

## Files in this repo

| File            | Role                                                                    |
|-----------------|-------------------------------------------------------------------------|
| `rt_shim.c`     | Build as `runc`, install to `/usr/bin/runc` on `.47`. Logs `CREATE` (and, opt-in, `START`). |
| `booted.c`      | Build as `booted`, install to `/root/container_volume/booted` on `.47`. Logs `BOOTED`. |
| `boot_bench.sh` | Driver loop. Runs on `.47`.                                             |
| `analyze.sh`    | Pairs records, prints min/mean/median/p99/max/stddev (µs) for create→booted. Runs on the **dev box** (busybox awk lacks `sqrt`). |
| `analyze_phases.sh` | Same stats but per phase (create→start / start→booted / create→booted), for `-s on` logs. Self-contained `sqrt`, so runs on the board too. |
| `extract_boot_ms.sh` | Print boot times (create→booted), one integer ms per line, for plotting. |
| `extract_phase_ms.sh` | Print a chosen phase (create→start / start→booted / create→booted) in ms; needs `-s on` runs for the first two. |
| `max_perf.sh`   | Lock all CPUs at max frequency. Copy on the board at `/root/max_perf.sh`; run after each reboot. |

---

## Prerequisites on the dev host

```sh
which aarch64-linux-gnu-gcc   # the cross-compiler (e.g. Ubuntu: apt install gcc-aarch64-linux-gnu)
which sshpass                 # non-interactive SSH auth (apt install sshpass)
```

Define the SSH/SCP helpers once per shell (note **`scp -O`** — mandatory, see gotchas):

```sh
SSH="sshpass -p root ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no"
SCP="sshpass -p root scp -O -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no"

# sanity: should print kernel info
$SSH root@192.168.100.47 uname -a
```

---

## Step 1 — Build the binaries (cross-compile on the dev host)

Both binaries **must be static**: `booted` runs inside the alpine/musl rootfs but
is built with a glibc toolchain; a fully static ELF needs no dynamic loader, so it
runs both in alpine and on the Buildroot host.

```sh
aarch64-linux-gnu-gcc -O2 -static -o runc   rt_shim.c
aarch64-linux-gnu-gcc -O2 -static -o booted booted.c
file runc booted
# Expected: "ELF 64-bit LSB executable, ARM aarch64, ... statically linked"
# (a harmless -Wunused-result warning on write() is expected)
```

> We build on the dev host because the target board has no usable native
> compiler. A fully static binary carries its own libc, so it needs nothing
> installed on the target at runtime.

---

## Step 2 — Deploy to the target board `.47`

```sh
# check free space first (rootfs can be small / in RAM)
$SSH root@192.168.100.47 'df -h /'

# copy artifacts + scripts
$SCP runc booted boot_bench.sh analyze.sh root@192.168.100.47:/root/

# place the container-side binary in the bind-mounted volume
$SSH root@192.168.100.47 'mkdir -p /root/container_volume && \
    mv /root/booted /root/container_volume/booted && \
    chmod +x /root/container_volume/booted /root/runc /root/boot_bench.sh /root/analyze.sh'

# verify arch on the board itself
$SSH root@192.168.100.47 'file /root/runc /root/container_volume/booted'
```

---

## Step 3 — Check the preconditions on `.47`

Run all checks:

```sh
$SSH root@192.168.100.47 '
echo "1. runphi present:";      ls -l /usr/bin/runphi
echo "2. cgroup v1 (tmpfs):";   grep " /sys/fs/cgroup " /proc/mounts
echo "3. cpu-rt-runtime set:";  grep -q cpu-rt-runtime /etc/docker/daemon.json && echo "yes (daemon.json)" || echo "NO"
echo "4. alpine image:";        docker images alpine
'
```

Then **empirically** confirm RT cgroup delegation actually works (the real test
for #3) — uses an already-present image and the current runtime, non-destructive:

```sh
$SSH root@192.168.100.47 \
  'docker run --rm --network none --cpu-rt-runtime=950000 --cpu-rt-period=1000000 ubuntu true; echo "exit=$?"'
# exit=0  → RT delegation OK
# exit=125 with "cpu.rt_runtime_us: invalid argument" → #3 is broken, fix in Step 4
```

What each precondition means:

| # | Check | Why it matters |
|---|-------|----------------|
| 1 | `/usr/bin/runphi` exists | The shim execs it; missing = every container dies. |
| 2 | `/sys/fs/cgroup` is `tmpfs` with v1 controllers | The harness assumes cgroup v1. (`stat -fc %T` from CLAUDE.md fails here — busybox `stat` has no `-f`; use `/proc/mounts`.) |
| 3 | dockerd knows `cpu-rt-runtime` | Without it the `/docker` cgroup slice has no RT bandwidth, so `boot_bench.sh`'s per-container `--cpu-rt-runtime=950000` errors out. |
| 4 | `alpine` image pulled (arm64) | Default benchmark image. |

---

## Step 4 — Fix preconditions (only what failed)

### #3 — give Docker RT bandwidth (`cpu-rt-runtime`)

Add `"cpu-rt-runtime": 950000` to `/etc/docker/daemon.json` **without disturbing
the `runtimes` block**, then restart dockerd. Current known-good `daemon.json`:

```json
{
  "cpu-rt-runtime": 950000,
  "runtimes": {
    "runphi":           { "path": "/usr/bin/runc" },
    "vanilla":          { "path": "/usr/local/sbin/runc_vanilla" },
    "runphi_listened":  { "path": "/usr/local/sbin/runc_listener", "runtimeArgs": ["/usr/bin/runc"] },
    "vanilla_listened": { "path": "/usr/local/sbin/runc_listener", "runtimeArgs": ["/usr/local/sbin/runc_vanilla"] }
  }
}
```

```sh
# back up, then restart. Watch that dockerd comes back before doing anything else.
$SSH root@192.168.100.47 '
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s)
  # ... edit daemon.json to the content above ...
  /etc/init.d/S60dockerd restart
  i=0; while [ $i -lt 30 ]; do docker version >/dev/null 2>&1 && break; sleep 1; i=$((i+1)); done
  docker version --format "server={{.Server.Version}}"
'
# re-run the empirical RT test from Step 3 — expect exit=0
```

### #4 — pull the alpine image

```sh
$SSH root@192.168.100.47 'docker pull alpine && docker images alpine'
```

> The `[::1]:53` DNS-at-boot problem is now **fixed permanently** — see
> [On-boot DNS fix](#on-boot-dns-fix). If you ever hit it on a board that lacks the
> fix, restarting dockerd (`/etc/init.d/S60dockerd restart`) makes it re-read the
> real resolver (`192.168.100.254`). Once alpine is cached locally, later reboots
> don't need the network anyway.

---

## Step 5 — Install the shim (destructive; safe procedure)

Overwriting `/usr/bin/runc` breaks Docker if the binary is wrong. Do it with a
backup + immediate smoke test + auto-restore:

```sh
$SSH root@192.168.100.47 '
  # NOTE: /usr/bin/runc is currently *runphi* (not vanilla). Back it up under a
  # clear name — do NOT copy it to runc_vanilla; the real vanilla lives at
  # /usr/local/sbin/runc_vanilla and must stay untouched.
  cp /usr/bin/runc /usr/bin/runc.pre_shim_bak
  cp /root/runc /usr/bin/runc && chmod +x /usr/bin/runc
  md5sum /usr/bin/runc /root/runc          # must match

  # smoke test: a plain container must still start (shim -> runphi -> vanilla)
  docker run --rm --network none ubuntu true; SMOKE=$?
  if [ $SMOKE -ne 0 ]; then
    echo "SMOKE FAILED — restoring runphi"; cp /usr/bin/runc.pre_shim_bak /usr/bin/runc
    exit 1
  fi
  echo "smoke OK"
'
```

End-to-end check — one real RT container that runs `booted`; expect a
`CREATE`+`BOOTED` pair sharing the same 12-char ID:

```sh
$SSH root@192.168.100.47 '
  docker run --rm --network none --cpu-rt-runtime=950000 --cpu-rt-period=1000000 \
    -v /root/container_volume:/home --privileged alpine /home/booted
  cat /root/container_volume/times.txt
'
# e.g.
#   CREATE 436370bc32d9 9504857994270
#   BOOTED 436370bc32d9 9505430368500   -> ~572 ms for this one warm sample
```

---

## Step 6 — Run the benchmark

Before a run, **lock the CPU frequency**: `$SSH root@192.168.100.47 /root/max_perf.sh`
(cpufreq resets on every boot — see [Lock CPU frequency](#lock-cpu-frequency)).

`boot_bench.sh` options: `-r N` reps (200), `-c on|off` drop caches between reps
(on), `-i IMAGE` (alpine), `-u SEC` up-time (2), `-g SEC` gap (3), `-p CPUS`
cpuset, `-w N` warm-up iterations to discard (1), `-n NETWORK` docker `--network`
value (none), `-s on|off` also timestamp OCI `start` (off). It launches `docker run
--rm -d --network $NETWORK --cpu-rt-runtime=950000 --cpu-rt-period=1000000
-v /root/container_volume:/home --privileged <img> /home/booted` each iteration.

It auto-manages the log: it runs `-w` warm-up container(s), **then truncates
`times.txt`**, so `analyze.sh` sees exactly the `-r N` measured samples with the
warm-up outlier already dropped — no manual pre-clear or first-row deletion needed.

```sh
# cold-start (caches dropped each iteration), 1 warm-up discarded (default):
$SSH root@192.168.100.47 'cd /root && ./boot_bench.sh -r 200 -c on'
# warm-start:
$SSH root@192.168.100.47 'cd /root && ./boot_bench.sh -r 200 -c off'

# compare the cost of networking: same run but with the bridge network:
$SSH root@192.168.100.47 'cd /root && ./boot_bench.sh -r 200 -c on -n bridge'
# keep the raw first sample (no warm-up):  ./boot_bench.sh -r 200 -w 0

# split the boot into create->start and start->booted (perturbs the baseline
# slightly, so run it as a SEPARATE experiment from the clean -s off numbers):
$SSH root@192.168.100.47 'cd /root && ./boot_bench.sh -r 200 -c on -s on'
```

At default timings a 200-rep run takes roughly `(200+w) × (2s up + 3s gap + ~1s) ≈ 20 min`.
The first container of a run is consistently an outlier; `-w 1` (default) absorbs
it. Bump to `-w 2` if a stray outlier ever survives.

---

## Step 7 — Analyze

```sh
$SSH root@192.168.100.47 './analyze.sh /root/container_volume/times.txt'
```

Output (all in **microseconds**), e.g.:

```
samples   : 199 (0 unpaired)
min       :   ...
mean      :   ...
median    :   ...
p99       :   ...
max       :   ...
stddev    :   ...
```

`samples` = paired CREATE/BOOTED records; `unpaired` = BOOTED with no matching
CREATE. Copy `times.txt` back to the dev host if you want to keep the raw data:
`$SCP root@192.168.100.47:/root/container_volume/times.txt ./times-$(date +%F).txt`

For **`-s on` logs** (with `START` records), use `analyze_phases.sh` to get the same
stats split into create→start, start→booted and create→booted — it runs on the board
or the dev box (self-contained `sqrt`), and treats a plain no-`START` log fine (start
phases just show `n=0`):

```sh
./analyze_phases.sh /root/container_volume/times.txt
# phase latencies (microseconds):
# create->start   n=200 min=... mean=... median=... p99=... max=... stddev=...
# start->booted   n=200 ...
# create->booted  n=200 ...
```

**For plots (violin/box), extract bare ms values, one per line** — both scripts run
on the board or the dev box (busybox-safe, unlike `analyze.sh`):

```sh
./extract_boot_ms.sh times.txt > boot_ms.txt                       # create->booted
./extract_phase_ms.sh -p create-start  times.txt > create_start.txt   # needs -s on
./extract_phase_ms.sh -p start-booted  times.txt > start_booted.txt   # needs -s on
```

---

## Lock CPU frequency

cpufreq settings **reset on every boot**, so run this once after each reboot
(before benchmarking) to keep the CPU pinned at its max:

```sh
$SSH root@192.168.100.47 /root/max_perf.sh
```

Note: this kernel ships **only the `userspace` cpufreq governor** — `performance`
is not compiled in (`scaling_available_governors` lists just `userspace`). So
`max_perf.sh` pins the frequency by setting `scaling_min_freq = scaling_max_freq =
cpuinfo_max_freq` (4× Cortex-A53 @ 1.2 GHz) rather than selecting a governor; it
prefers `performance` automatically if a future kernel provides it. The repo copy
is `max_perf.sh`; the board copy is `/root/max_perf.sh`.

It also disables **deep cpuidle states** (keeping only `WFI`/state0) to reduce
wake-up jitter — but this kernel has `CONFIG_CPU_IDLE` **off**, so there are no
cpuidle states at all: the CPU already only does architectural `WFI` on idle, and
the script just reports "nothing to disable". The logic is there so it works
automatically if the kernel is ever rebuilt with cpuidle.

---

## Rollback / uninstall

Everything changed on `.47` is reversible:

```sh
# 1. restore the original runtime (runphi) over the shim
$SSH root@192.168.100.47 'cp /usr/bin/runc.pre_shim_bak /usr/bin/runc && chmod +x /usr/bin/runc'
#    (equivalently: cp /usr/bin/runphi /usr/bin/runc — they are byte-identical)

# 2. revert the daemon.json cpu-rt-runtime change
$SSH root@192.168.100.47 'cp /etc/docker/daemon.json.bak.preshim /etc/docker/daemon.json && \
    /etc/init.d/S60dockerd restart'

# 3. (optional) smoke test after restoring
$SSH root@192.168.100.47 'docker run --rm ubuntu true; echo exit=$?'
```

---

## Deviations & gotchas

Discovered the hard way — check these first if something misbehaves.

| Symptom / situation | Cause | Fix |
|---|---|---|
| `scp` → `sh: /usr/libexec/sftp-server: not found` | Board has no SFTP server | Use `scp -O` (legacy protocol). |
| SSH/scp hang waiting for a password | Non-interactive shell | Prefix with `sshpass -p root`. |
| CLAUDE.md says back up `/usr/bin/runc` → `runc_vanilla` | **`/usr/bin/runc` is runphi, not vanilla** (md5-identical to `/usr/bin/runphi`) | Back it up as `runc.pre_shim_bak`. Never overwrite the real vanilla at `/usr/local/sbin/runc_vanilla`. |
| `docker run --cpu-rt-runtime=...` → exit 125, `cpu.rt_runtime_us: invalid argument` | dockerd not started with `cpu-rt-runtime`; `/docker` slice has 0 RT bandwidth | Add `"cpu-rt-runtime": 950000` to `daemon.json`, restart dockerd. |
| `docker pull` → DNS error on `[::1]:53` (after a reboot) | `/etc/resolv.conf` is volatile (`→ /tmp`); dockerd (S60) starts before dhcpcd (S41) fills it in | **Fixed permanently** — see [On-boot DNS fix](#on-boot-dns-fix). Stopgap: `/etc/init.d/S60dockerd restart`. |
| `stat -fc %T /sys/fs/cgroup` → `stat: not found` | busybox `stat` lacks `-f` | Use `grep /sys/fs/cgroup /proc/mounts` instead. |

### Reference: key paths on `.47`

| Path | What |
|---|---|
| `/usr/bin/runc` | Default OCI runtime = **the shim** (after install); was runphi. |
| `/usr/bin/runc.pre_shim_bak` | Backup of the original runc (= runphi). |
| `/usr/bin/runphi` | Real RT runtime the shim execs into. |
| `/usr/local/sbin/runc_vanilla` | Real vanilla runc (runphi redirects standard containers here). Do not touch. |
| `/etc/docker/daemon.json` | Has `cpu-rt-runtime` + the `runtimes` map. Backup: `daemon.json.bak.preshim`. |
| `/etc/init.d/S60dockerd` | dockerd init script. Patched with a DNS wait (see below). Backup: `S60dockerd.bak.predns`. |
| `/usr/bin/gcc` | Optional containerized-gcc wrapper (see below). On `.52` the real gcc is backed up as `/usr/bin/gcc.native`. |
| `/run/rt_measure_start` | Marker: when present, the shim also logs `START`. Managed by `boot_bench.sh -s on`; ephemeral (cleared on reboot). |
| `/root/max_perf.sh` | Locks CPUs at max frequency; run after each reboot. |
| `/root/container_volume/` | Bind-mounted into containers as `/home`. Holds `booted` and `times.txt`. |
| `/root/container_volume/times.txt` | The `CREATE`/`START`/`BOOTED` log all sides append to. |

---

## On-boot DNS fix

**Problem:** `/etc/resolv.conf` is a symlink into volatile `/tmp`, so it's empty at
every boot. `dhcpcd` (init `S41`) fills it in, but `dockerd` (`S60`) can start
first; with no nameserver yet, dockerd's registry resolver sticks on the `[::1]:53`
loopback fallback and `docker pull` fails until dockerd is restarted.

**Fix (installed on both boards):** `/etc/init.d/S60dockerd`'s `do_start()` now
waits (up to 20 s) for a `nameserver` line in `/etc/resolv.conf` before launching
dockerd. So dockerd always comes up with a working resolver — no manual restart
after reboot. Original saved as `/etc/init.d/S60dockerd.bak.predns`.

```sh
# revert on a board if ever needed:
$SSH root@<board> 'cp /etc/init.d/S60dockerd.bak.predns /etc/init.d/S60dockerd'
```

> Both boards are Buildroot; a full image rebuild would overwrite this patch (and
> the `gcc` wrapper). `.52` is NFS-root (exported from `192.168.100.45`), so the
> edit lives in that shared export.

## Optional: compile on the board (containerized gcc)

The boards have no usable native toolchain, but both run Docker, so a `builder`
image (`alpine` + `build-base`, musl) provides gcc on demand. `/usr/bin/gcc` is a
wrapper that runs that image with the current dir bind-mounted, so it behaves like
a normal gcc:

```sh
$SSH root@<board> 'cd /root && gcc -O2 -static -o booted booted.c && file booted'
# musl -static yields a static-PIE ELF; add -no-pie for a classic non-PIE static binary.
```

Rebuild the `builder` image (e.g. after `docker system prune`):

```sh
$SSH root@<board> "printf 'FROM alpine\nRUN apk add --no-cache build-base\n' | docker build -t builder -"
```

This is a convenience for on-board tinkering; the benchmark binaries are still
built on the dev host (Step 1) and copied over.

---

## Style notes (if you edit the scripts)

- POSIX `sh` only — no bashisms (`[[ ]]`, arrays, `for (( ))`, `${var,,}`, `$EPOCHREALTIME`).
- Keep expensive work (file open, path resolution, forks) **out** of the window
  between the timestamp and the runtime invocation — that window is what's measured.
