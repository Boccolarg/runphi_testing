#!/usr/bin/env python3
"""m4.py - the students' own procedure (M4_SCRIPTS in runphi_testing),
replicated on the KV260. Called by rtbench.py for campaigns named m4_*:

    m4_steady                    run_no_interference.sh
    m4_<profile>                 run_{cpu,mem,io}_stress.sh <profile>
    m4_life_cold, m4_life_warm   run_latency_start_stop.sh cold|warm

Their scripts cannot run as they are on the board (busybox has no taskset,
no grep -P, no date +%N), so this module performs the same steps in the
same order. Each iteration runs runc and then runPHI, as theirs do.

cyclictest run (steady and stress profiles):
  1. start stress-ng with their arguments, pinned to CPUs 0-2 (taskset -c
     0-2), --timeout 60s in theirs, 180s here (see STRESS_DURATION; not
     for steady);
  2. start vmstat -t 1, pinned to CPUs 0-2;
  3. sleep 2 s (1 s for steady);
  4. runc: docker run --rm <flags> rt-cyclictest:runc cyclictest -p 99
     -i 1000 -l 30000 -m -a 3 -q -h 1000, output captured;
     runPHI: docker run -d <flags> rt-cyclictest:runphi <same command,
     which runPHI ignores>, docker wait, the guest's serial log, docker rm.
     The guest runs cyclictest itself at boot (images/kvm/S99m4) and powers
     off;
  5. stop vmstat and stress-ng (SIGTERM), sleep 1 s.
Min/Avg/Max are read as theirs are: the first "Min:"/"# Min Latencies:"
(etc.) in the output.

Lifecycle run: (cold: sync, drop_caches) vmstat; docker create, docker
start, sleep 1 s, docker stop -t 10, docker rm, each timed; stop vmstat.

Results go to results_m4/ in the layout of rtbench.py's results/
(ffi_<runtime>_<profile>, steady as "baseline"; life_<runtime>_<mode>),
so analysis/analyze.py reads them unchanged.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import time

import rtbench as rb

RESULTS_M4 = os.path.join(rb.ROOT, "results_m4")
# Their hdd_sync files go to /var/tmp/stress_ssd, a directory on the PC's
# disk. On the board /var/tmp is the tmpfs /tmp, so use the SD card instead.
HDD_DIR = os.path.join(rb.ROOT, "stress_ssd")

# Their --timeout 60s covers x86's container start (about 2 s) plus the 30 s
# of cyclictest. On the KV260 runPHI needs 9-45 s to start a guest under
# stress, so 60 s would end the stress during the measurement. stress-ng is
# stopped after every run anyway (kill -TERM, as theirs), so the timeout is
# only a backstop: 180 s.
STRESS_DURATION = "180s"
STRESS = {  # their stress-ng arguments, verbatim (run_{cpu,mem,io}_stress.sh)
    "matrixprod": ["--cpu", "3", "--cpu-method", "matrixprod"],
    "callfunc": ["--cpu", "3", "--cpu-method", "callfunc"],
    "irq": ["--timer", "3", "--timer-freq", "1000000"],
    "memcpy": ["--memcpy", "3", "--vm-bytes", "384M", "--vm-keep"],
    "tlb_shootdown": ["--tlb-shootdown", "3"],
    "stream": ["--stream", "3"],
    "hdd_sync": ["--hdd", "3", "--hdd-bytes", "512M", "--hdd-opts", "direct,rd-rnd,noatime",
                 "--temp-path", HDD_DIR],
    "io_uring": ["--io-uring", "3", "--temp-path", "/tmp"],
    "socket": ["--udp", "3"],
}

IMAGE = {"runc": "rt-cyclictest:runc", "kvm": "rt-cyclictest:runphi"}
QUICK_IMAGE = {"runc": "rt-cyclictest:runc", "kvm": "rt-cyclictest:runphi-quick"}  # guest: -l 3000
RUNTIME = {"runc": "runc", "kvm": "runphi"}
FLAGS = ["--cpuset-cpus=" + rb.ISO_CPU, "--memory=1024m", "--net=none", "--cap-add=SYS_NICE",
         "--ulimit", "rtprio=99", "--ulimit", "memlock=-1"]


def cyclictest_cmd(quick):
    return ["cyclictest", "-p", "99", "-i", "1000", "-l", "3000" if quick else "30000",
            "-m", "-a", rb.ISO_CPU, "-q", "-h", "1000"]


def taskset_hk():
    os.sched_setaffinity(0, rb.HOUSEKEEPING_SET)


# Their parsing: grep -oP '(?:Min:|# Min Latencies:)\s*0*\K[0-9]+' | head -n 1
def first_value(label, text):
    m = re.search(r"(?:%s:|# %s Latencies:)\s*0*(\d+)" % (label, label), text)
    return int(m.group(1)) if m else None


def parse(text):
    vals = {k + "_us": first_value(k, text) for k in ("Min", "Avg", "Max")}
    rec = {"min_us": vals["Min_us"], "avg_us": vals["Avg_us"], "max_us": vals["Max_us"]}
    # The same, from the histogram's own summary only: their first-match
    # parse would pick up a "Max:" printed earlier in the guest's serial log.
    for k in ("Min", "Avg", "Max"):
        m = re.search(r"# %s Latencies:\s*(\d+)" % k, text)
        rec["%s_hist_us" % k.lower()] = int(m.group(1)) if m else None
    m = re.search(r"# Total:\s*(\d+)", text)
    rec["cycles"] = int(m.group(1)) if m else None
    m = re.search(r"# Histogram Overflows:\s*(\d+)", text)
    rec["hist_overflows"] = int(m.group(1)) if m else None
    return rec


def vmstat_all_means(path):
    """Mean in/s and cs/s over every vmstat sample of the run but the first
    (the average since boot): their vmstat files cover the whole run."""
    rows, hdr = [], None
    for line in rb.read_text(path).splitlines():
        f = line.split()
        if "cs" in f and "in" in f:
            hdr = f
        elif f and f[0].isdigit():
            rows.append(f)
    if not hdr or len(rows) < 2:
        return None
    i_in, i_cs = hdr.index("in"), hdr.index("cs")
    rows = rows[1:]
    return {"in_per_s": sum(int(r[i_in]) for r in rows) / len(rows),
            "cs_per_s": sum(int(r[i_cs]) for r in rows) / len(rows),
            "samples": len(rows), "window": "whole run"}


class Proc:
    """A background process pinned to the housekeeping CPUs, output to a file."""

    def __init__(self, cmd, path, cwd=None):
        self.f = open(path, "w")
        self.p = subprocess.Popen(cmd, stdout=self.f, stderr=subprocess.STDOUT, cwd=cwd,
                                  preexec_fn=taskset_hk)

    def running(self):
        return self.p.poll() is None

    def stop(self):  # kill -TERM $PID; wait $PID
        if self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(timeout=120)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        self.f.close()
        return self.p.returncode


def wait_guest(cid, path, rec, tmp, timeout):
    """docker wait, guarded against the teardown livelock (rtbench.py)."""
    deadline = rb.now() + timeout
    powered_off = None
    while rb.container_status(cid) == "running":
        if rb.now() > deadline:
            raise rb.RunError("guest still running after %d s" % timeout)
        if not rb.libvirtd_ok():
            raise rb.LibvirtdGone("libvirtd stopped during the run")
        if powered_off is None and "reboot: Power down" in rb.read_text(path):
            powered_off = rb.now()
        if powered_off is not None and rb.now() - powered_off > 15 and "qemu_killed" not in rec:
            pid = rb.qemu_pid(cid)
            rec["qemu_killed"] = True
            if pid:
                try:
                    with open(os.path.join(tmp, "livelock.txt"), "w") as f:
                        f.write(rb.thread_report(pid) + "\n")
                    os.kill(pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
                rb.log("QEMU livelocked after the guest's poweroff: killed (pid %d)" % pid)
        time.sleep(0.5)
    if powered_off is not None:
        rec["poweroff_to_exit_s"] = round(rb.now() - powered_off, 2)


def ffi_run(runtime, profile, idx, rundir, quick):
    tmp = os.path.join(rb.SCRATCH, "m4-%s-%s-%02d" % (runtime, profile, idx))
    os.makedirs(tmp, exist_ok=True)
    rec = {"runtime": runtime, "profile": profile, "run": idx, "quick": quick, "procedure": "M4_SCRIPTS"}
    stress = vm = None
    cid = None
    try:
        if profile != "baseline":
            os.makedirs(HDD_DIR, exist_ok=True)
            stress = Proc([rb.STRESS_NG] + STRESS[profile] + ["--timeout", STRESS_DURATION],
                          os.path.join(tmp, "stress.txt"), cwd=rb.STRESS_TMP)
        vm = Proc(["vmstat", "-t", "1"], os.path.join(tmp, "vmstat.txt"))
        time.sleep(2 if stress else 1)
        t0 = rb.now()
        cmd = cyclictest_cmd(quick)
        image = (QUICK_IMAGE if quick else IMAGE)[runtime]
        if runtime == "runc":
            p = subprocess.run(["docker", "run", "--rm", "--runtime=runc"] + FLAGS + [image] + cmd,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                               timeout=300)
            raw = p.stdout
            if p.returncode != 0:
                raise rb.RunError("docker run (runc) exited %d: %s" % (p.returncode, p.stderr.strip()[-300:]))
        else:
            cid = rb.sh(["docker", "run", "-d", "--runtime=runphi"] + FLAGS + [image] + cmd)
            path = rb.console_path("kvm", cid)
            wait_guest(cid, path, rec, tmp, 300)
            raw = rb.read_text(path)
            rb.sh(["docker", "rm", cid], timeout=180)
            cid = None
        rec["t_container_s"] = round(rb.now() - t0, 3)
        rec["stress_running_at_end"] = stress.running() if stress else None
        with open(os.path.join(tmp, "console.log"), "w") as f:
            f.write(raw)
        rec.update(parse(raw))
        vm.stop()
        vm = None
        rec["vmstat"] = vmstat_all_means(os.path.join(tmp, "vmstat.txt"))
        if stress:
            rec["stress_rc"] = stress.stop()
            stress = None
        expected = 3000 if quick else 30000
        if rec["max_us"] is None or rec["cycles"] != expected:
            raise rb.RunError("incomplete cyclictest output (cycles %s)" % rec["cycles"])
        rec["parse_agrees"] = all(rec[k + "_us"] == rec[k + "_hist_us"] for k in ("min", "avg", "max"))
        left = rb.leftovers()
        if left:
            raise rb.RunError("left behind: " + "; ".join(left))
        time.sleep(1)
    finally:
        for proc in (vm, stress):
            if proc is not None:
                try:
                    proc.stop()
                except Exception as e:
                    rb.log("cleanup step failed: %r" % e)
        if cid is not None and rb.libvirtd_ok():
            rb.try_sh(["docker", "rm", "-f", cid], 180)
        if os.path.isdir(rundir):
            n = 1
            while os.path.exists("%s.failed%d" % (rundir, n)):
                n += 1
            os.rename(rundir, "%s.failed%d" % (rundir, n))
        shutil.move(tmp, rundir)
    return rec


def life_run(runtime, mode, idx, rundir, quick):
    rec = {"runtime": runtime, "mode": mode, "run": idx, "procedure": "M4_SCRIPTS"}
    if mode == "cold":  # sync; echo 3 > drop_caches (no pause after it)
        subprocess.run(["sync"])
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("3\n")
    os.makedirs(rundir, exist_ok=True)
    vm = Proc(["vmstat", "-t", "1"], os.path.join(rundir, "vmstat.txt"))
    cid = None
    try:
        rt = RUNTIME[runtime]
        t0 = rb.now()
        cid = rb.sh(["docker", "create", "--runtime=" + rt] + FLAGS + [IMAGE[runtime]] + cyclictest_cmd(quick))
        t1 = rb.now()
        t2 = rb.now()
        rb.sh(["docker", "start", cid])
        t3 = rb.now()
        time.sleep(1)
        t4 = rb.now()
        rb.sh(["docker", "stop", "-t", "10", cid])
        t5 = rb.now()
        t6 = rb.now()
        rb.sh(["docker", "rm", cid])
        t7 = rb.now()
        cid = None
        ms = lambda a, b: round((b - a) * 1000.0, 3)
        rec.update({"create_ms": ms(t0, t1), "start_ms": ms(t2, t3), "stop_ms": ms(t4, t5),
                    "rm_ms": ms(t6, t7)})
        rec["total_ms"] = round(rec["create_ms"] + rec["start_ms"] + rec["stop_ms"] + rec["rm_ms"], 3)
        left = rb.leftovers()
        if left:
            raise rb.RunError("left behind: " + "; ".join(left))
    finally:
        vm.stop()
        if cid is not None and (rb.libvirtd_ok() or runtime == "runc"):
            rb.try_sh(["docker", "rm", "-f", cid], 180)
    return rec


def campaign(name, runs, quick):
    what = name[len("m4_"):]
    if what in ("life_cold", "life_warm"):
        mode = what[len("life_"):]
        dirs = {rt: "life_%s_%s" % (rt, mode) for rt in ("runc", "kvm")}
        run = lambda rt, i, d: life_run(rt, mode, i, d, quick)
    else:
        profile = "baseline" if what == "steady" else what
        if profile != "baseline" and profile not in STRESS:
            raise SystemExit("unknown M4 profile %r" % what)
        dirs = {rt: "ffi_%s_%s" % (rt, profile) for rt in ("runc", "kvm")}
        run = lambda rt, i, d: ffi_run(rt, profile, i, d, quick)
    base = RESULTS_M4 + ("_quick" if quick else "")
    out = {rt: os.path.join(base, d) for rt, d in dirs.items()}
    done = {}
    for rt, d in out.items():
        os.makedirs(d, exist_ok=True)
        done[rt] = len([l for l in rb.read_text(os.path.join(d, "runs.jsonl")).splitlines() if l.strip()])
        with open(os.path.join(d, "host_state_boot%s.txt" % rb.read_text(
                "/proc/sys/kernel/random/boot_id").strip()[:8]), "w") as f:
            f.write(rb.sh([os.path.join(rb.ROOT, "bench", "rt_tune.sh"), "--show"], check=False))
    os.makedirs(rb.SCRATCH, exist_ok=True)
    rb.log("campaign %s: runc %d/%d, kvm %d/%d runs already done" % (name, done["runc"], runs, done["kvm"], runs))
    if not rb.libvirtd_ok():
        rb.log("libvirtd is not running: reboot needed")
        return 3
    if rb.leftovers():
        rb.log("cleaning up leftovers: " + "; ".join(rb.leftovers()))
        if not rb.cleanup():
            return 3
    failures = 0
    i = min(done.values()) + 1
    while i <= runs:
        for rt in ("runc", "kvm"):
            if done[rt] >= i:
                continue
            while True:
                rundir = os.path.join(out[rt], "run_%02d" % i)
                try:
                    rec = run(rt, i, rundir)
                except rb.LibvirtdGone as e:
                    rb.log("%s run %d DISCARDED: %s" % (rt, i, e))
                    with open(os.path.join(out[rt], "errors.log"), "a") as f:
                        f.write("run %d: %s\n" % (i, e))
                    rb.cleanup()
                    return 3
                except (rb.RunError, subprocess.TimeoutExpired) as e:
                    failures += 1
                    rb.log("%s run %d FAILED (%d): %s" % (rt, i, failures, e))
                    with open(os.path.join(out[rt], "errors.log"), "a") as f:
                        f.write("run %d: %s\n" % (i, e))
                    if not rb.cleanup():
                        return 3
                    if failures >= 3:
                        rb.log("campaign %s aborted after 3 consecutive failures" % name)
                        return 2
                    time.sleep(10)
                    continue
                break
            failures = 0
            with open(os.path.join(out[rt], "runs.jsonl"), "a") as f:
                f.write(json.dumps(rec) + "\n")
                f.flush()
                os.fsync(f.fileno())
            done[rt] = i
            rb.bump_progress()
            if "max_us" in rec:
                rb.log("%-4s run %2d: min %3s avg %3s max %4s us  container %.1fs  stress alive at end: %s" % (
                    rt, i, rec["min_us"], rec["avg_us"], rec["max_us"], rec["t_container_s"],
                    rec["stress_running_at_end"]))
            else:
                rb.log("%-4s run %2d: create %.0f start %.0f stop %.0f rm %.0f ms" % (
                    rt, i, rec["create_ms"], rec["start_ms"], rec["stop_ms"], rec["rm_ms"]))
        i += 1
    rb.log("campaign %s complete" % name)
    return 0
