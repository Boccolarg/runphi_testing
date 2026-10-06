#!/usr/bin/env python3
"""order_probe.py [variant] - does running a guest make later runc runs worse
under tlb_shootdown? On a fresh boot, with the students' procedure
(m4.ffi_run): runc runs under tlb_shootdown, then one guest, then runc runs
again. The variants differ in what runs in between:

  runphi_tlb   runPHI guest under tlb_shootdown, 5 runc runs before and after
               (the first probe, the default)
  runphi       runPHI guest (docker, vCPU on CPU 3), no stress
  qemu_cpu3    plain QEMU/KVM guest, without libvirt or runPHI, all its
               threads on CPU 3; same kernel and initramfs as runPHI's
               (cyclictest 30 s, then poweroff)
  qemu_cpu2    the same on CPU 2: nothing of KVM ever runs on CPU 3
  qemu_paused  plain QEMU/KVM started paused (-S) on CPU 3: the VM and its
               vCPU are created but never run; stopped after 5 s
  qemu_nopmu   qemu_cpu3 without a virtual PMU (-cpu host,pmu=off)
  qemu_tiny    plain QEMU/KVM on CPU 3 with bench/tiny_guest.S instead of
               Linux: one line on the UART, then PSCI SYSTEM_OFF
  none         nothing (control)

Each runc run also records the interrupts CPU 3 took, per source
(/proc/interrupts), and, when /root/rtbench/bin/pmucount is installed
(bench/pmucount.c), the PMU counts of every CPU, kernel and user: cycles,
instructions, TLB refills, ... Results in
/root/rtbench/probe_order/<variant>/. Run
as a campaign of the queue, probe_<variant> (rtbench.py), so that each
variant gets its own boot.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, "/root/rtbench/bench")
import rtbench as rb  # noqa: E402
import m4  # noqa: E402

OUT = os.path.join(rb.ROOT, "probe_order")
QEMU = "/usr/bin/qemu-system-aarch64"
KERNEL = "/root/guest/Image"
INITRD = os.path.join(OUT, "rootfs-m4.cpio.gz")  # rt-cyclictest:runphi's, S99m4
TINY = os.path.join(rb.ROOT, "bin", "tiny_guest.elf")  # bench/tiny_guest.S
PMUCOUNT = os.path.join(rb.ROOT, "bin", "pmucount")  # bench/pmucount.c
VARIANTS = ("runphi_tlb", "runphi", "qemu_cpu3", "qemu_cpu2", "qemu_paused", "qemu_nopmu",
            "qemu_tiny", "none")


def cpu3_interrupts():
    """{source: count on CPU 3} from /proc/interrupts."""
    counts = {}
    with open("/proc/interrupts") as f:
        cpus = f.readline().split()
        col = cpus.index("CPU" + rb.ISO_CPU)
        for line in f:
            fields = line.split()
            if len(fields) <= col + 1 or not fields[0].endswith(":"):
                continue
            try:
                n = int(fields[col + 1])
            except ValueError:
                continue
            counts[fields[0][:-1] + " " + " ".join(fields[len(cpus) + 1:])] = n
    return counts


def histogram_over(rundir, us):
    n = 0
    with open(os.path.join(rundir, "console.log"), errors="replace") as f:
        for line in f:
            m = re.match(r"^(\d{6})\s+(\d+)", line)
            if m and int(m.group(1)) > us:
                n += int(m.group(2))
    return n


def runc_step(variant, step, phase):
    rundir = os.path.join(OUT, variant, "step_%02d_runc" % step)
    pmu = None
    if os.path.isfile(PMUCOUNT):
        pmu = subprocess.Popen([PMUCOUNT], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True)
        time.sleep(0.2)
    try:
        t0, before = time.time(), cpu3_interrupts()
        rec = m4.ffi_run("runc", "tlb_shootdown", step, rundir, False)
        dt, after = time.time() - t0, cpu3_interrupts()
    finally:
        if pmu is not None:
            pmu.send_signal(signal.SIGTERM)
            out, err = pmu.communicate(timeout=30)
    rate = {k: round((after[k] - before.get(k, 0)) / dt, 1) for k in after if after[k] != before.get(k, 0)}
    rec.update(step=step, phase=phase, samples_over_60us=histogram_over(rundir, 60),
               cpu3_irq_per_s=rate, cpu3_irq_total_per_s=round(sum(rate.values()), 1))
    if pmu is not None:
        if pmu.returncode != 0:
            raise rb.RunError("pmucount exited %d: %s" % (pmu.returncode, err.strip()))
        rec["pmu"] = json.loads(out)
    return rec


def extract_initrd():
    if os.path.isfile(INITRD):
        return
    cid = rb.sh(["docker", "create", m4.IMAGE["kvm"], "/bin/true"])
    try:
        rb.sh(["docker", "cp", cid + ":/boot/rootfs.cpio.gz", INITRD + ".new"])
    finally:
        rb.try_sh(["docker", "rm", cid], 60)
    os.rename(INITRD + ".new", INITRD)


def qemu_guest(cpu, rundir, paused=False, pmu=True, tiny=False):
    """A plain QEMU/KVM guest, every thread on <cpu>: like libvirt's command
    line for runPHI, without libvirt. The Linux guest runs cyclictest for
    30 s and powers off; tiny_guest.elf powers off at once."""
    os.makedirs(rundir, exist_ok=True)
    log = os.path.join(rundir, "console.log")
    if tiny:
        boot = ["-kernel", TINY]
    else:
        extract_initrd()
        boot = ["-kernel", KERNEL, "-initrd", INITRD, "-append", "console=ttyAMA0"]
    cmd = [QEMU, "-machine", "virt,gic-version=host", "-accel", "kvm",
           "-cpu", "host" if pmu else "host,pmu=off",
           "-m", "1024", "-overcommit", "mem-lock=on", "-smp", "1", "-display", "none",
           "-nodefaults", "-no-user-config"] + boot + [
           "-serial", "file:" + log, "-monitor", "none", "-no-reboot"] + (["-S"] if paused else [])
    rec = {"cpu": cpu, "paused": paused, "pmu": pmu, "tiny": tiny}
    t0 = rb.now()
    with open(os.path.join(rundir, "qemu.txt"), "w") as out:
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT,
                             preexec_fn=lambda: os.sched_setaffinity(0, {cpu}))
        try:
            if paused:
                time.sleep(5)
                p.send_signal(signal.SIGTERM)
            rec["qemu_rc"] = p.wait(30 if paused else 240)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            raise rb.RunError("QEMU did not exit")
    rec["qemu_s"] = round(rb.now() - t0, 2)
    if tiny:
        if "TINY GUEST" not in rb.read_text(log) or rec["qemu_rc"] != 0:
            raise rb.RunError("the tiny guest did not run (rc %s)" % rec["qemu_rc"])
    elif not paused:
        text = rb.read_text(log)
        if "RTBENCH END" not in text:
            raise rb.RunError("the guest did not finish (no RTBENCH END)")
        rec.update(m4.parse(text))
    return rec


def disturb(variant, step):
    rundir = os.path.join(OUT, variant, "step_%02d_%s" % (step, variant))
    if variant in ("runphi_tlb", "runphi"):
        rec = m4.ffi_run("kvm", "tlb_shootdown" if variant == "runphi_tlb" else "baseline",
                         step, rundir, False)
    elif variant == "none":
        rec = {}
    else:
        rec = qemu_guest(2 if variant == "qemu_cpu2" else int(rb.ISO_CPU), rundir,
                         paused=variant == "qemu_paused", pmu=variant != "qemu_nopmu",
                         tiny=variant == "qemu_tiny")
    if not os.path.isdir("/sys/kernel/debug/kvm"):
        subprocess.run(["mount", "-t", "debugfs", "none", "/sys/kernel/debug"])
    if os.path.isdir("/sys/kernel/debug/kvm"):  # VMs still known to KVM
        rec["kvm_debugfs_vms"] = [d for d in os.listdir("/sys/kernel/debug/kvm")
                                  if os.path.isdir(os.path.join("/sys/kernel/debug/kvm", d))]
    rec.update(step=step, phase="guest", what=variant)
    return rec


def campaign(variant):
    if variant not in VARIANTS:
        raise SystemExit("variant must be one of " + ", ".join(VARIANTS))
    n = 5 if variant == "runphi_tlb" else 3
    d = os.path.join(OUT, variant)
    shutil.rmtree(d, ignore_errors=True)  # a variant needs a fresh boot: start over
    os.makedirs(d)
    with open(os.path.join(d, "runs.jsonl"), "w") as f:
        for i, phase in enumerate(["before"] * n + ["guest"] + ["after"] * n, 1):
            rec = disturb(variant, i) if phase == "guest" else runc_step(variant, i, phase)
            f.write(json.dumps(rec) + "\n")
            f.flush()
            rb.bump_progress()
            if phase == "guest":
                rb.log("step %2d %-11s %s" % (i, variant, {k: rec.get(k) for k in ("max_us", "qemu_s", "qemu_rc")}))
            else:
                rb.log("step %2d runc %-6s max %4s avg %3s >60us %5d  CPU3 irq/s %s" % (
                    i, phase, rec["max_us"], rec["avg_us"], rec["samples_over_60us"], rec["cpu3_irq_total_per_s"]))
    rb.log("PROBE DONE " + variant)
    return 0


if __name__ == "__main__":
    sys.exit(campaign(sys.argv[1] if len(sys.argv) > 1 else "runphi_tlb"))
