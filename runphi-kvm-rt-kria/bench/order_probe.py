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
  none         nothing (control)

Each runc run also records the interrupts CPU 3 took, per source
(/proc/interrupts). Results in /root/rtbench/probe_order/<variant>/. Run
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
VARIANTS = ("runphi_tlb", "runphi", "qemu_cpu3", "qemu_cpu2", "qemu_paused", "none")


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
    t0, before = time.time(), cpu3_interrupts()
    rec = m4.ffi_run("runc", "tlb_shootdown", step, rundir, False)
    dt, after = time.time() - t0, cpu3_interrupts()
    rate = {k: round((after[k] - before.get(k, 0)) / dt, 1) for k in after if after[k] != before.get(k, 0)}
    rec.update(step=step, phase=phase, samples_over_60us=histogram_over(rundir, 60),
               cpu3_irq_per_s=rate, cpu3_irq_total_per_s=round(sum(rate.values()), 1))
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


def qemu_guest(cpu, paused, rundir):
    """A plain QEMU/KVM guest, every thread on <cpu>: like libvirt's command
    line for runPHI (bench/README), without libvirt."""
    extract_initrd()
    os.makedirs(rundir, exist_ok=True)
    log = os.path.join(rundir, "console.log")
    cmd = [QEMU, "-machine", "virt,gic-version=host", "-accel", "kvm", "-cpu", "host",
           "-m", "1024", "-overcommit", "mem-lock=on", "-smp", "1", "-display", "none",
           "-nodefaults", "-no-user-config", "-kernel", KERNEL, "-initrd", INITRD,
           "-append", "console=ttyAMA0", "-serial", "file:" + log, "-monitor", "none",
           "-no-reboot"] + (["-S"] if paused else [])
    rec = {"cpu": cpu, "paused": paused}
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
    if not paused:
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
        rec = qemu_guest(2 if variant == "qemu_cpu2" else int(rb.ISO_CPU),
                         variant == "qemu_paused", rundir)
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
