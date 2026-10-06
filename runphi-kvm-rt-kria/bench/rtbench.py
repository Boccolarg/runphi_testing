#!/usr/bin/env python3
"""rtbench.py - runPHI-KVM vs runc on the Kria KV260 (reproduction of the
Capone/Cecchini/Colucci campaign, see ../README.md).

    rtbench.py campaign <name> [--runs N] [--quick]
    rtbench.py check

A campaign name is
    ffi_<runtime>_<profile>     cyclictest under a stress profile
    life_<runtime>_<cold|warm>  container lifecycle timing
with <runtime> runc or kvm. Results go to RESULTS/<name>/: runs.jsonl (one
JSON object per completed run, the campaign resumes after the last one) and a
run_NN/ directory with the raw data of each run.

Freedom from interference run (ffi_*):
  1. docker run the benchmark container (runc) or guest (kvm, runPHI);
  2. when it prints "RTBENCH READY", start vmstat 1 and the stressors
     (stress-ng pinned to the housekeeping CPUs 0-2);
  3. the container/guest waits WARMUP s, then runs
     cyclictest -p 99 -i 1000 -l LOOPS -m -a <iso> -q  (LOOPS x 1 ms);
  4. when cyclictest has printed its summary, stop the stressors and vmstat,
     wait for the container to exit (the guest powers off), docker rm.
Lifecycle run (life_*):
  cold: sync + drop_caches first; then docker create, docker start, (wait for
  "RTBENCH READY", settle 2 s), docker stop, docker rm, each timed. warm: one
  discarded run first, then the runs back to back.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = "/root/rtbench"
RESULTS = os.path.join(ROOT, "results")
STATE = os.path.join(ROOT, "state")
STRESS_NG = os.path.join(ROOT, "bin", "stress-ng")
STRESS_TMP = os.path.join(ROOT, "stress-tmp")  # on the SD card (the root fs)
SCRATCH = "/tmp/rtbench"  # tmpfs: nothing is written to the SD card while measuring

ISO_CPU = "3"
HOUSEKEEPING = "0-2"
HOUSEKEEPING_SET = {0, 1, 2}
NWORKERS = "3"  # one stress-ng worker per housekeeping CPU

# The students' container configuration ("Runtime & Docker config"), used for
# both runtimes. For runPHI the vCPU pinning, memory and IRQ steering come
# from the image's /boot/config.json; these flags put QEMU in the same cgroup
# limits as the runc container.
DOCKER_FLAGS = ["--cpuset-cpus", ISO_CPU, "-m", "1024m", "--network", "none",
                "--cap-add", "SYS_NICE", "--ulimit", "rtprio=99",
                "--ulimit", "memlock=-1"]

FULL = {"warmup": 30, "loops": 30000}
QUICK = {"warmup": 5, "loops": 5000}

PROFILES = {
    "baseline": [],
    # CPU
    "matrixprod": ["--cpu", NWORKERS, "--cpu-method", "matrixprod"],
    "callfunc": ["--cpu", NWORKERS, "--cpu-method", "callfunc"],
    "irq": ["--timer", NWORKERS],
    # memory
    "memcpy": ["--memcpy", NWORKERS],
    "stream": ["--stream", NWORKERS],
    "tlb_shootdown": ["--tlb-shootdown", NWORKERS],
    # I/O (temp files on the SD card)
    "hdd_sync": ["--hdd", NWORKERS, "--hdd-bytes", "256M", "--hdd-opts", "wr-rnd,fsync"],
    "io_uring": ["--io-uring", NWORKERS],
    "socket": ["--udp", NWORKERS],
}

CT_RE = re.compile(r"T:\s*0\s*\(\s*\d+\)\s*P:\s*(\d+)\s*I:\s*(\d+)\s*C:\s*(\d+)\s*"
                   r"Min:\s*(\d+)\s*Act:\s*(\d+)\s*Avg:\s*(\d+)\s*Max:\s*(\d+)[ \t]*\r?\n")
# The line must be complete (newline): the guest's serial console arrives a
# few characters at a time, and a read in the middle of "Max:     367" would
# otherwise yield 36.

now = time.monotonic


class RunError(Exception):
    pass


class LibvirtdGone(Exception):
    """libvirtd stopped during a run. Without it a guest that powers off
    keeps its QEMU (started with -no-shutdown) and its container forever, and
    runPHI cannot destroy it: the board has to be rebooted."""


def log(msg):
    print("[%9.1f] %s" % (float(open("/proc/uptime").read().split()[0]), msg), flush=True)


def sh(cmd, check=True, timeout=300):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       timeout=timeout, universal_newlines=True)
    if check and p.returncode != 0:
        raise RunError("%s failed (%d): %s" % (" ".join(cmd), p.returncode, p.stderr.strip()))
    return p.stdout.strip()


def try_sh(cmd, timeout=120):
    """sh() for cleanup paths: never raises, None if it failed or hung."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout, universal_newlines=True)
    except (subprocess.TimeoutExpired, OSError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def libvirtd_ok():
    """libvirtd runs and its socket exists (virsh needs both)."""
    return os.path.exists("/run/libvirt/libvirt-sock") and try_sh(["pidof", "libvirtd"], 10) is not None


def qemu_pid(cid):
    """PID of the QEMU process of runPHI container `cid`, or None."""
    needle = ("guest=runphi-%s" % cid[:24]).encode()
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                with open("/proc/%s/cmdline" % d, "rb") as f:
                    if needle in f.read():
                        return int(d)
            except OSError:
                pass
    return None


def thread_report(pid):
    """Scheduling state of every thread of `pid` (for the livelock record)."""
    out = []
    for t in sorted(os.listdir("/proc/%d/task" % pid), key=int):
        base = "/proc/%d/task/%s" % (pid, t)
        try:
            comm = read_text(base + "/comm").strip()
            st = read_text(base + "/stat").rsplit(")", 1)[1].split()
            sw = [l for l in read_text(base + "/status").splitlines() if "ctxt_switches" in l]
            out.append("%s %-16s state=%s utime=%s stime=%s cpu=%s rtprio=%s policy=%s %s" % (
                t, comm, st[0], st[11], st[12], st[36], st[37], st[38], " ".join(sw)))
        except (OSError, IndexError):
            pass
    return "\n".join(out)


def bump_progress():
    os.makedirs(STATE, exist_ok=True)
    path = os.path.join(STATE, "progress")
    try:
        n = int(open(path).read())
    except (OSError, ValueError):
        n = 0
    with open(path + ".new", "w") as f:
        f.write("%d\n" % (n + 1))
    os.replace(path + ".new", path)


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except FileNotFoundError:
        return ""


# ---------------------------------------------------------------- containers

def image(runtime, quick):
    if runtime == "runc":
        return "rtbench-runc:alpine"
    return "rtbench-kvm:quick" if quick else "rtbench-kvm:full"


def run_args(runtime, quick):
    args = ["--runtime=runphi"] if runtime == "kvm" else []
    args += DOCKER_FLAGS
    if runtime == "runc":
        p = QUICK if quick else FULL
        args += ["-e", "WARMUP=%d" % p["warmup"], "-e", "LOOPS=%d" % p["loops"],
                 "-e", "CPU=" + ISO_CPU]
    return args


def console_path(runtime, cid):
    """File where the container's console output appears."""
    if runtime == "kvm":
        return "/var/log/libvirt/qemu/runphi-%s-serial.log" % cid[:24]
    return sh(["docker", "inspect", "-f", "{{.LogPath}}", cid])


def console_text(runtime, path):
    text = read_text(path)
    if runtime == "runc":  # json-file log driver: one JSON object per line
        out = []
        for line in text.splitlines():
            try:
                out.append(json.loads(line)["log"])
            except (ValueError, KeyError):
                pass
        text = "".join(out)
    return text


def container_status(cid):
    return sh(["docker", "inspect", "-f", "{{.State.Status}}", cid], check=False)


def wait_for(runtime, path, cid, needle, timeout, poll=0.05, on_tick=None):
    """Wait until `needle` (str or compiled regex) shows up on the console."""
    deadline = now() + timeout
    last_status_check = 0
    while True:
        text = console_text(runtime, path)
        m = needle.search(text) if hasattr(needle, "search") else (needle in text and needle)
        if m:
            return m, text
        t = now()
        if on_tick:
            on_tick(t)
        if t > deadline:
            raise RunError("timeout waiting for %r" % getattr(needle, "pattern", needle))
        if t - last_status_check > 5:
            last_status_check = t
            st = container_status(cid)
            if st not in ("running", "created"):
                text = console_text(runtime, path)
                m = needle.search(text) if hasattr(needle, "search") else (needle in text and needle)
                if m:
                    return m, text
                raise RunError("container is %s while waiting for %r" % (st, getattr(needle, "pattern", needle)))
        time.sleep(poll)


def leftovers():
    out = []
    names = sh(["docker", "ps", "-a", "--filter", "name=rtb-", "-q"], check=False)
    if names:
        out.append("containers: " + names.replace("\n", " "))
    doms = sh(["virsh", "list", "--all", "--name"], check=False)
    if doms.strip():
        out.append("domains: " + doms.replace("\n", " "))
    if os.path.isdir("/run/runPHI") and os.listdir("/run/runPHI"):
        out.append("/run/runPHI: " + " ".join(os.listdir("/run/runPHI")))
    return out


def cleanup():
    """Remove what a failed run left behind. Returns False if a container
    could not be removed."""
    ok = True
    if not libvirtd_ok():
        # A guest whose QEMU outlived libvirtd: only killing QEMU ends its
        # watcher, and so its container.
        pids = try_sh(["pidof", "qemu-system-aarch64"], 10)
        if pids:
            subprocess.run(["kill", "-9"] + pids.split())
            time.sleep(2)
    ids = try_sh(["docker", "ps", "-a", "--filter", "name=rtb-", "-q"]) or ""
    for cid in ids.split():
        if try_sh(["docker", "rm", "-f", cid], 120) is None:
            ok = False
    if libvirtd_ok():
        for dom in (try_sh(["virsh", "list", "--all", "--name"]) or "").split():
            if dom.startswith("runphi-"):
                try_sh(["virsh", "destroy", dom])
    subprocess.run(["sh", "-c", "rm -rf %s/*" % STRESS_TMP])
    return ok


# ---------------------------------------------------------------- host stats

class Vmstat:
    """vmstat -n 1 in the background, to tmpfs."""

    def __init__(self, path):
        self.path = path
        self.f = open(path, "w")
        self.t0 = now()
        self.p = subprocess.Popen(["vmstat", "-n", "1"], stdout=self.f, stderr=subprocess.STDOUT)

    def stop(self):
        self.p.terminate()
        self.p.wait()
        self.f.close()

    def window_means(self, t_begin, t_end):
        """Mean in/s and cs/s over the vmstat lines whose 1 s interval lies in
        [t_begin, t_end]. Line 0 is the average since boot; line k (k >= 1)
        covers [t0 + k - 1, t0 + k]."""
        lines = [l.split() for l in read_text(self.path).splitlines() if l.strip()]
        hdr = next((l for l in lines if "cs" in l and "in" in l), None)
        rows = [l for l in lines if l and l[0].isdigit()]
        if not hdr or len(rows) < 2:
            return None
        i_in, i_cs = hdr.index("in"), hdr.index("cs")
        sel = [r for k, r in enumerate(rows) if k >= 1
               and self.t0 + k - 1 >= t_begin and self.t0 + k <= t_end]
        if not sel:
            return None
        return {"in_per_s": sum(int(r[i_in]) for r in sel) / len(sel),
                "cs_per_s": sum(int(r[i_cs]) for r in sel) / len(sel),
                "samples": len(sel)}


def cpu_irqs(cpu):
    """Total interrupts taken by `cpu` so far, from /proc/interrupts."""
    lines = read_text("/proc/interrupts").splitlines()
    ncpu = len(lines[0].split())
    total = 0
    for line in lines[1:]:
        f = line.split()
        if len(f) > ncpu and f[0].endswith(":"):
            try:
                total += int(f[1 + cpu])
            except ValueError:
                pass
    return total


class Stress:
    def __init__(self, profile, seconds, path):
        self.p = None
        self.f = open(path, "w")
        args = PROFILES[profile]
        if not args:
            return
        os.makedirs(STRESS_TMP, exist_ok=True)
        cmd = [STRESS_NG] + args + ["--taskset", HOUSEKEEPING, "--temp-path", STRESS_TMP,
                                    "--timeout", "%ds" % seconds, "--metrics-brief"]
        self.f.write(" ".join(cmd) + "\n")
        self.f.flush()
        self.p = subprocess.Popen(cmd, cwd=STRESS_TMP, stdout=self.f, stderr=subprocess.STDOUT,
                                  start_new_session=True)

    def running(self):
        return self.p is None or self.p.poll() is None

    def stop(self):
        if self.p is not None and self.p.poll() is None:
            os.killpg(self.p.pid, signal.SIGINT)
            try:
                self.p.wait(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(self.p.pid, signal.SIGKILL)
                self.p.wait()
        self.f.close()
        return None if self.p is None else self.p.returncode


# ---------------------------------------------------------------- FFI run

def ffi_run(runtime, profile, idx, rundir, quick):
    p = QUICK if quick else FULL
    measure = p["loops"] / 1000.0
    name = "rtb-%s-%s-%02d" % (runtime, profile, idx)
    tmp = os.path.join(SCRATCH, name)
    os.makedirs(tmp, exist_ok=True)
    rec = {"runtime": runtime, "profile": profile, "run": idx, "quick": quick,
           "warmup_s": p["warmup"], "loops": p["loops"]}
    vm = stress = None
    cid = None
    try:
        t_launch = now()
        cid = sh(["docker", "run", "-d", "--name", name] + run_args(runtime, quick) + [image(runtime, quick)])
        rec["t_docker_run"] = now() - t_launch
        path = console_path(runtime, cid)
        wait_for(runtime, path, cid, "RTBENCH READY", 180)
        t_ready = now()
        rec["t_ready"] = t_ready - t_launch
        vm = Vmstat(os.path.join(tmp, "vmstat.txt"))
        stress = Stress(profile, p["warmup"] + measure + 90, os.path.join(tmp, "stress.txt"))
        t_meas = t_ready + p["warmup"]
        snap = {}

        def tick(t):
            if "irq0" not in snap and t >= t_meas:
                snap["irq0"] = cpu_irqs(int(ISO_CPU))
                snap["t0"] = t
            if not stress.running():
                raise RunError("stress-ng exited early (rc %s)" % stress.p.returncode)

        m, _ = wait_for(runtime, path, cid, CT_RE, p["warmup"] + measure + 120, poll=0.2, on_tick=tick)
        t_result = now()
        irq1 = cpu_irqs(int(ISO_CPU))
        rec["t_result"] = t_result - t_launch
        if "irq0" in snap:
            rec["iso_cpu_irqs_per_s"] = (irq1 - snap["irq0"]) / max(t_result - snap["t0"], 1e-3)
        stress_ok = stress.running()
        rc = stress.stop()
        stress = None
        vm.stop()
        rec["vmstat"] = vm.window_means(t_meas, t_result)
        vm = None
        if not stress_ok:
            raise RunError("stress-ng was not running at the end of the measurement")
        rec["stress_rc"] = rc
        prio, intv, count, mn, act, avg, mx = (int(x) for x in m.groups())
        if count != p["loops"] or prio != 99 or intv != 1000:
            raise RunError("unexpected cyclictest summary: %s" % m.group(0))
        rec.update({"min_us": mn, "act_us": act, "avg_us": avg, "max_us": mx, "cycles": count})

        # the container exits by itself (runc: cyclictest ends; kvm: poweroff)
        deadline = now() + 90
        powered_off = None
        while container_status(cid) == "running" and now() < deadline:
            if runtime == "kvm":
                if not libvirtd_ok():
                    raise LibvirtdGone("libvirtd stopped during the run (cyclictest had finished: %s)" % m.group(0))
                if powered_off is None and "reboot: Power down" in console_text(runtime, path):
                    powered_off = now()
                if powered_off is not None and now() - powered_off > 15 and "qemu_killed" not in rec:
                    # Teardown livelock (README, "Teardown livelock"): after the
                    # guest's PSCI SYSTEM_OFF the SCHED_FIFO 99 vCPU thread can
                    # keep CPU 3 busy inside KVM_RUN, so QEMU's main thread, also
                    # confined to CPU 3 by the container cpuset, never runs: QEMU
                    # neither exits nor answers libvirt, and docker stop/rm hang.
                    # The measurement is complete: record it, then kill QEMU.
                    pid = qemu_pid(cid)
                    rec["qemu_killed"] = True
                    if pid:
                        try:
                            with open(os.path.join(tmp, "livelock.txt"), "w") as f:
                                f.write("guest powered off %.1f s ago, container still running\n" % (now() - powered_off))
                                f.write(read_text("/proc/stat").splitlines()[4] + "\n")
                                f.write(thread_report(pid) + "\n")
                                time.sleep(1)
                                f.write("1 s later:\n" + read_text("/proc/stat").splitlines()[4] + "\n")
                                f.write(thread_report(pid) + "\n")
                        except Exception as e:
                            log("livelock report failed: %r" % e)
                        log("run %d: QEMU livelocked after the guest's poweroff: killing it (pid %d)" % (idx, pid))
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
            time.sleep(0.5)
        if powered_off is not None:
            rec["poweroff_to_exit_s"] = round(now() - powered_off, 2)
        rec["exit_status"] = container_status(cid)
        with open(os.path.join(tmp, "console.log"), "w") as f:
            f.write(console_text(runtime, path))
        sh(["docker", "rm", "-f", cid], timeout=180)
        cid = None
        left = leftovers()
        if left:
            raise RunError("left behind: " + "; ".join(left))
    finally:
        # every step may fail (e.g. docker hanging on a guest that libvirtd
        # left behind): none of them may keep the raw data from being saved
        for step in (lambda: stress is not None and stress.stop(),
                     lambda: vm is not None and vm.stop()):
            try:
                step()
            except Exception as e:
                log("cleanup step failed: %r" % e)
        if cid is not None:
            try:
                with open(os.path.join(tmp, "console.log"), "w") as f:
                    f.write(console_text(runtime, console_path(runtime, cid)))
            except Exception:
                pass
            if libvirtd_ok() or runtime == "runc":
                try_sh(["docker", "rm", "-f", cid], 180)
        # raw data: tmpfs -> SD card, only now that the run is over
        if os.path.isdir(rundir):  # a failed earlier attempt of this run: keep it aside
            n = 1
            while os.path.exists("%s.failed%d" % (rundir, n)):
                n += 1
            os.rename(rundir, "%s.failed%d" % (rundir, n))
        shutil.move(tmp, rundir)
    return rec


# ---------------------------------------------------------------- lifecycle run

def drop_caches():
    subprocess.run(["sync"])
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("3\n")
    time.sleep(2)


def lifecycle_run(runtime, mode, idx, rundir, quick):
    name = "rtb-life-%s-%s-%02d" % (runtime, mode, idx)
    rec = {"runtime": runtime, "mode": mode, "run": idx}
    if mode == "cold":
        drop_caches()
    cid = None
    try:
        t0 = now()
        cid = sh(["docker", "create", "--name", name] + run_args(runtime, False) + [image(runtime, False)])
        t1 = now()
        sh(["docker", "start", cid])
        t2 = now()
        path = console_path(runtime, cid)
        wait_for(runtime, path, cid, "RTBENCH READY", 180, poll=0.01)
        t3 = now()
        time.sleep(2)
        t4 = now()
        sh(["docker", "stop", cid])
        t5 = now()
        sh(["docker", "rm", cid])
        t6 = now()
        cid = None
        ms = lambda a, b: round((b - a) * 1000.0, 3)
        rec.update({"create_ms": ms(t0, t1), "start_ms": ms(t1, t2), "ready_ms": ms(t2, t3),
                    "stop_ms": ms(t4, t5), "rm_ms": ms(t5, t6)})
        rec["total_ms"] = round(rec["create_ms"] + rec["start_ms"] + rec["stop_ms"] + rec["rm_ms"], 3)
        rec["total_with_ready_ms"] = round(rec["total_ms"] + rec["ready_ms"], 3)
        left = leftovers()
        if left:
            raise RunError("left behind: " + "; ".join(left))
    finally:
        if cid is not None and (libvirtd_ok() or runtime == "runc"):
            try_sh(["docker", "rm", "-f", cid], 180)
    return rec


# ---------------------------------------------------------------- campaign

def parse_name(name):
    parts = name.split("_", 2)
    if len(parts) != 3 or parts[0] not in ("ffi", "life") or parts[1] not in ("runc", "kvm"):
        raise SystemExit("bad campaign name %r" % name)
    kind, runtime, what = parts
    if kind == "ffi" and what not in PROFILES:
        raise SystemExit("unknown profile %r" % what)
    if kind == "life" and what not in ("cold", "warm"):
        raise SystemExit("lifecycle mode must be cold or warm, not %r" % what)
    return kind, runtime, what


def campaign(name, runs, quick):
    kind, runtime, what = parse_name(name)
    outdir = os.path.join(RESULTS + ("_quick" if quick else ""), name)
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(SCRATCH, exist_ok=True)
    jsonl = os.path.join(outdir, "runs.jsonl")
    done = len([l for l in read_text(jsonl).splitlines() if l.strip()])
    log("campaign %s: %d/%d runs already done" % (name, done, runs))
    with open(os.path.join(outdir, "host_state_boot%s.txt" % read_text(
            "/proc/sys/kernel/random/boot_id").strip()[:8]), "w") as f:
        f.write(sh([os.path.join(ROOT, "bench", "rt_tune.sh"), "--show"], check=False))
    if runtime == "kvm" and not libvirtd_ok():
        log("libvirtd is not running: reboot needed")
        return 3
    leftover = leftovers()
    if leftover:
        log("cleaning up leftovers: " + "; ".join(leftover))
        if not cleanup():
            return 3
    if kind == "life" and what == "warm" and done < runs:
        log("warm-up run (discarded)")
        lifecycle_run(runtime, what, 0, None, quick)
    failures = 0
    idx = done + 1
    while idx <= runs:
        rundir = os.path.join(outdir, "run_%02d" % idx)
        try:
            if kind == "ffi":
                rec = ffi_run(runtime, what, idx, rundir, quick)
            else:
                rec = lifecycle_run(runtime, what, idx, rundir, quick)
        except LibvirtdGone as e:
            log("run %d DISCARDED: %s" % (idx, e))
            with open(os.path.join(outdir, "errors.log"), "a") as f:
                f.write("run %d: %s\n" % (idx, e))
            cleanup()
            log("reboot needed, the campaign resumes at run %d" % idx)
            return 3
        except (RunError, subprocess.TimeoutExpired) as e:
            failures += 1
            log("run %d FAILED (%d): %s" % (idx, failures, e))
            with open(os.path.join(outdir, "errors.log"), "a") as f:
                f.write("run %d: %s\n" % (idx, e))
            if not cleanup():
                log("could not clean up after run %d: reboot needed" % idx)
                return 3
            if failures >= 3:
                log("campaign %s aborted after 3 consecutive failures" % name)
                return 2
            time.sleep(10)
            continue
        failures = 0
        with open(jsonl, "a") as f:
            f.write(json.dumps(rec) + "\n")
            f.flush()
            os.fsync(f.fileno())
        bump_progress()
        if kind == "ffi":
            log("run %2d: min %3d avg %3d max %4d us  ready %.1fs  vmstat %s" % (
                idx, rec["min_us"], rec["avg_us"], rec["max_us"], rec["t_ready"], rec["vmstat"]))
        else:
            log("run %2d: create %.0f start %.0f ready %.0f stop %.0f rm %.0f ms" % (
                idx, rec["create_ms"], rec["start_ms"], rec["ready_ms"], rec["stop_ms"], rec["rm_ms"]))
        idx += 1
        time.sleep(3)
    log("campaign %s complete" % name)
    return 0


def main():
    os.sched_setaffinity(0, HOUSEKEEPING_SET)
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    if args[0] == "check":
        print(sh([os.path.join(ROOT, "bench", "rt_tune.sh"), "--show"], check=False))
        print("leftovers:", leftovers() or "none")
        return 0
    if args[0] == "campaign" and len(args) >= 2:
        runs = 30
        if "--runs" in args:
            runs = int(args[args.index("--runs") + 1])
        if args[1].startswith("probe_"):  # runc before/after a guest, see order_probe.py
            import order_probe
            return order_probe.campaign(args[1][len("probe_"):])
        if args[1].startswith("m4_"):  # the students' own procedure, see m4.py
            import m4
            return m4.campaign(args[1], runs, "--quick" in args)
        return campaign(args[1], runs, "--quick" in args)
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
