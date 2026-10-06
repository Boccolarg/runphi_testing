#!/usr/bin/env python3
"""order_probe.py: does a runPHI guest run make later runc runs worse under
tlb_shootdown? M4 procedure (m4.ffi_run), fresh boot: 5 runc, 1 kvm, 5 runc."""
import json, os, re, sys
sys.path.insert(0, "/root/rtbench/bench")
import rtbench as rb  # noqa: E402
import m4  # noqa: E402

OUT = "/root/rtbench/probe_order"
os.makedirs(OUT, exist_ok=True)
seq = ["runc"] * 5 + ["kvm"] + ["runc"] * 5
with open(os.path.join(OUT, "runs.jsonl"), "a") as f:
    for i, rt in enumerate(seq, 1):
        rundir = os.path.join(OUT, "step_%02d_%s" % (i, rt))
        rec = m4.ffi_run(rt, "tlb_shootdown", i, rundir, False)
        h = {}
        for l in open(os.path.join(rundir, "console.log"), errors="replace"):
            m = re.match(r"^(\d{6})\s+(\d+)", l)
            if m:
                h[int(m.group(1))] = int(m.group(2))
        rec["samples_over_60us"] = sum(v for k, v in h.items() if k > 60)
        rec["step"] = i
        f.write(json.dumps(rec) + "\n")
        f.flush()
        print("step %2d %-4s max %4s avg %3s >60us %5d" % (i, rt, rec["max_us"], rec["avg_us"], rec["samples_over_60us"]), flush=True)
print("PROBE DONE", flush=True)
