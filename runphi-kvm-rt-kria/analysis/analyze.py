#!/usr/bin/env python3
"""analyze.py <results_dir> <out_dir> [--compare <dir> <label>] - tables and figures of the KV260
reproduction, in the form of the students' paper (Table II, Figs. 2-6 and the
vmstat slides).

<results_dir> is a copy of the board's /root/rtbench/results (one directory
per campaign, each with runs.jsonl). Writes to <out_dir>:
  summary.md        the tables
  lifecycle.png     Fig. 2: lifecycle phases, cold and warm
  baseline.png      Fig. 3: Min / Avg / Max without stress
  cpu.png mem.png io.png   Figs. 4-6 and slides: Avg and Max latency per profile
  host_activity.png slides: context switches/s and interrupts/s (vmstat)
  summary.json      every number in the tables
With --compare, the campaigns of another results directory (e.g. those
measured before a runPHI change, or with the other procedure) are set against
the ones of <results_dir>, for each runtime measured in both: comparison.png
and a table in summary.md.
"""

import json
import os
import re
import statistics as st
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

RUNTIMES = [("runc", "runc (cgroups/namespaces)"), ("kvm", "runPHI-KVM (KVM isolation)")]
COLOR = {"runc": "#2a78d6", "kvm": "#eb6834"}  # categorical slots 1-2, validated
PHASE_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]  # slots 1-4
INK, INK2, MUTED, GRID, AXIS, SURFACE = "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7", "#fcfcfb"

GROUPS = {
    "cpu": [("matrixprod", "CPU: Matrixprod (ALU)"), ("callfunc", "CPU: Callfunc (recursion)"),
            ("irq", "CPU: Timer / IRQ")],
    "mem": [("memcpy", "MEM: Memcpy (bandwidth)"), ("tlb_shootdown", "MEM: TLB shootdown (IPI)"),
            ("stream", "MEM: STREAM bandwidth")],
    "io": [("hdd_sync", "IO: HDD sync (block/FS)"), ("io_uring", "IO: io_uring (async)"),
           ("socket", "IO: Socket / UDP")],
}
GROUP_TITLE = {"cpu": "CPU stress", "mem": "Memory stress", "io": "I/O stress"}
PROFILE_LABEL = {p: l for g in GROUPS.values() for p, l in g}
PROFILE_LABEL["baseline"] = "Baseline (no stress)"


def style():
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "axes.edgecolor": AXIS, "axes.labelcolor": INK2, "axes.titlecolor": INK,
        "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
        "axes.grid": True, "axes.grid.axis": "y", "grid.color": GRID, "grid.linewidth": 0.6,
        "axes.spines.top": False, "axes.spines.right": False,
        "font.size": 9, "axes.titlesize": 10, "legend.frameon": False,
    })


CT_LINE = re.compile(r"T:\s*0\s*\(\s*\d+\)\s*P:\s*\d+\s*I:\s*\d+\s*C:\s*(\d+)\s*"
                     r"Min:\s*(\d+)\s*Act:\s*(\d+)\s*Avg:\s*(\d+)\s*Max:\s*(\d+)[ \t]*\r?\n")


# cyclictest -h (the students' procedure, bench/m4.py): no T: line, but the
# histogram's own summary.
HIST = {k: re.compile(r"# %s:\s*(\d+)" % label) for k, label in (
    ("cycles", "Total"), ("min_us", "Min Latencies"), ("avg_us", "Avg Latencies"), ("max_us", "Max Latencies"))}


def console_values(text):
    lines = list(CT_LINE.finditer(text))
    if lines:
        return dict(zip(("cycles", "min_us", "act_us", "avg_us", "max_us"),
                        (int(v) for v in lines[-1].groups())))
    vals = {k: rx.search(text) for k, rx in HIST.items()}
    if all(vals.values()):
        return {k: int(m.group(1)) for k, m in vals.items()}
    return None


def load(results, notes):
    """runs.jsonl of every campaign. For cyclictest runs, the numbers are
    checked against the complete summary line in run_NN/console.log, the raw
    record, which wins if they differ (the harness once read a line that the
    guest's serial console had only half written)."""
    data = {}
    for name in sorted(os.listdir(results)):
        path = os.path.join(results, name, "runs.jsonl")
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            runs = [json.loads(l) for l in f if l.strip()]
        for r in runs if name.startswith("ffi_") else []:
            con = os.path.join(results, name, "run_%02d" % r["run"], "console.log")
            if not os.path.isfile(con):
                continue
            with open(con, errors="replace") as f:
                vals = console_values(f.read())
            if not vals:
                notes.append("%s run %d: no complete cyclictest summary in console.log" % (name, r["run"]))
                continue
            diff = {k: (r.get(k), v) for k, v in vals.items() if r.get(k) != v}
            if diff:
                notes.append("%s run %d: corrected from console.log: %s" % (
                    name, r["run"], ", ".join("%s %s -> %s" % (k, a, b) for k, (a, b) in diff.items())))
                r.update(vals)
        data[name] = runs
    return data


def stats(xs):
    if not xs:
        return None
    return {"n": len(xs), "mean": st.mean(xs), "median": st.median(xs), "min": min(xs),
            "max": max(xs), "stdev": st.stdev(xs) if len(xs) > 1 else 0.0}


def legend_handles():
    from matplotlib.patches import Patch
    return [Patch(facecolor=COLOR[r], edgecolor=COLOR[r], label=l) for r, l in RUNTIMES]


def paired_boxes(ax, groups, values, ylabel):
    """groups: x labels; values[runtime][i] = list of numbers for group i."""
    width, gap = 0.34, 0.04
    for k, (rt, _) in enumerate(RUNTIMES):
        pos = [i + (k - 0.5) * (width + gap) for i in range(len(groups))]
        vals = [v if v else [float("nan")] for v in values[rt]]
        ax.boxplot(vals, positions=pos, widths=width, patch_artist=True, showfliers=True,
                   boxprops=dict(facecolor=COLOR[rt], edgecolor=COLOR[rt], alpha=0.9),
                   medianprops=dict(color=INK, linewidth=1.2),
                   whiskerprops=dict(color=COLOR[rt], linewidth=1),
                   capprops=dict(color=COLOR[rt], linewidth=1),
                   flierprops=dict(marker="o", markersize=4, markerfacecolor="none",
                                   markeredgecolor=COLOR[rt]))
    ax.set_xticks(range(len(groups)))
    ax.set_xticklabels(groups)
    ax.set_ylabel(ylabel)
    ax.set_ylim(bottom=0)


# ------------------------------------------------------------------ lifecycle

def lifecycle(data, out, md, js):
    phases = ["create_ms", "start_ms", "stop_ms", "rm_ms"]
    rows, bars = [], []
    for rt, label in RUNTIMES:
        for mode in ("cold", "warm"):
            runs = data.get("life_%s_%s" % (rt, mode))
            if not runs:
                continue
            s = {p: stats([r[p] for r in runs if r.get(p) is not None])
                 for p in phases + ["total_ms", "ready_ms"]}
            js["life_%s_%s" % (rt, mode)] = s
            rows.append((rt, mode, s))
            bars.append(("%s\n(%s)" % ("runc" if rt == "runc" else "runPHI-KVM", mode), s))
    if not rows:
        return
    md.append("## Lifecycle (Table II), mean over runs, ms\n")
    md.append("| Runtime | Caches | n | Create | Start | Stop | RM | **Total** | Start→ready (extra) |")
    md.append("|---|---|---|---|---|---|---|---|---|")
    for rt, mode, s in rows:  # no start→ready in the students' procedure (bench/m4.py)
        md.append("| %s | %s | %d | %.1f | %.1f | %.1f | %.1f | **%.1f** | %s |" % (
            "runc" if rt == "runc" else "runPHI-KVM", mode, s["total_ms"]["n"],
            s["create_ms"]["mean"], s["start_ms"]["mean"], s["stop_ms"]["mean"],
            s["rm_ms"]["mean"], s["total_ms"]["mean"],
            "%.1f" % s["ready_ms"]["mean"] if s["ready_ms"] else "-"))
    md.append("")
    md.append("Standard deviations (ms): " + "; ".join(
        "%s %s total %.1f, start %.1f" % (rt, mode, s["total_ms"]["stdev"], s["start_ms"]["stdev"])
        for rt, mode, s in rows) + "\n")

    fig, ax = plt.subplots(figsize=(6.5, 4))
    for i, (lab, s) in enumerate(bars):
        bottom = 0
        for j, p in enumerate(phases):
            h = s[p]["mean"]
            ax.bar(i, h, bottom=bottom, width=0.55, color=PHASE_COLORS[j], edgecolor=SURFACE,
                   linewidth=1.5, label=p[:-3].upper() if i == 0 else None)
            bottom += h
        ax.text(i, bottom, "Total:\n%.1f ms" % bottom, ha="center", va="bottom", fontsize=8, color=INK)
    ax.set_xticks(range(len(bars)))
    ax.set_xticklabels([b[0] for b in bars])
    ax.set_ylabel("Execution time (ms)")
    ax.set_ylim(0, max(sum(s[p]["mean"] for p in phases) for _, s in bars) * 1.18)
    ax.legend(title="Phase", loc="upper left")
    ax.set_title("Container lifecycle on the KV260 (mean of %d runs)" % rows[0][2]["total_ms"]["n"])
    fig.tight_layout()
    fig.savefig(os.path.join(out, "lifecycle.png"), dpi=160)
    plt.close(fig)


# ------------------------------------------------------------------ cyclictest

def ffi_runs(data, rt, profile):
    return data.get("ffi_%s_%s" % (rt, profile), [])


def ffi_tables(data, md, js):
    md.append("## cyclictest (µs) per profile\n")
    windows = {r["vmstat"].get("window", "cyclictest window") for k, v in data.items() if k.startswith("ffi_")
               for r in v if r.get("vmstat")} or {"cyclictest window"}
    md.append("Min and Avg: median over runs. Max: mean, median and worst over runs. "
              "Host vmstat (mean over the %s) and interrupts/s on the isolated CPU 3.\n"
              % " / ".join(sorted(windows)))
    md.append("| Profile | Runtime | n | Min | Avg | Max mean | Max median | Max worst | cs/s | in/s | CPU3 irq/s |")
    md.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for profile in ["baseline"] + [p for g in GROUPS.values() for p, _ in g]:
        for rt, _ in RUNTIMES:
            runs = ffi_runs(data, rt, profile)
            if not runs:
                continue
            s = {k: stats([r[k] for r in runs]) for k in ("min_us", "avg_us", "max_us")}
            vm = [r["vmstat"] for r in runs if r.get("vmstat")]
            s["cs_per_s"] = stats([v["cs_per_s"] for v in vm])
            s["in_per_s"] = stats([v["in_per_s"] for v in vm])
            s["iso_irq_per_s"] = stats([r["iso_cpu_irqs_per_s"] for r in runs if "iso_cpu_irqs_per_s" in r])
            js["ffi_%s_%s" % (rt, profile)] = s
            md.append("| %s | %s | %d | %g | %g | %.2f | %g | %g | %s | %s | %s |" % (
                profile, "runc" if rt == "runc" else "runPHI-KVM", s["max_us"]["n"],
                s["min_us"]["median"], s["avg_us"]["median"], s["max_us"]["mean"],
                s["max_us"]["median"], s["max_us"]["max"],
                "%.0f" % s["cs_per_s"]["mean"] if s["cs_per_s"] else "-",
                "%.0f" % s["in_per_s"]["mean"] if s["in_per_s"] else "-",
                "%.0f" % s["iso_irq_per_s"]["mean"] if s["iso_irq_per_s"] else "-"))
    md.append("")


def baseline_fig(data, out):
    if not any(ffi_runs(data, rt, "baseline") for rt, _ in RUNTIMES):
        return
    fig, ax = plt.subplots(figsize=(6, 3.8))
    vals = {rt: [[r[k] for r in ffi_runs(data, rt, "baseline")] for k in ("min_us", "avg_us", "max_us")]
            for rt, _ in RUNTIMES}
    paired_boxes(ax, ["Min", "Average", "Max (peak)"], vals, "Latency (µs)")
    ax.legend(handles=legend_handles(), loc="upper left")
    ax.set_title("Baseline (no stress), %d runs × 30,000 iterations" % max(len(v[0]) for v in vals.values()))
    fig.tight_layout()
    fig.savefig(os.path.join(out, "baseline.png"), dpi=160)
    plt.close(fig)


def group_fig(data, out, group):
    profiles = GROUPS[group]
    if not any(ffi_runs(data, rt, p) for rt, _ in RUNTIMES for p, _ in profiles):
        return
    fig, axes = plt.subplots(2, 1, figsize=(6.5, 6.5), sharex=True)
    for ax, key, ylabel in ((axes[0], "avg_us", "Avg latency (µs)"), (axes[1], "max_us", "Max latency (µs)")):
        vals = {rt: [[r[key] for r in ffi_runs(data, rt, p)] for p, _ in profiles] for rt, _ in RUNTIMES}
        paired_boxes(ax, [l for _, l in profiles], vals, ylabel)
    axes[0].legend(handles=legend_handles(), loc="upper left")
    axes[0].set_title("%s: average and maximum cyclictest latency" % GROUP_TITLE[group])
    plt.setp(axes[1].get_xticklabels(), rotation=12, ha="right")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "%s.png" % group), dpi=160)
    plt.close(fig)


def host_activity_fig(data, out):
    profiles = [p for g in GROUPS.values() for p, _ in g]
    if not any(ffi_runs(data, rt, p) for rt, _ in RUNTIMES for p in profiles):
        return
    fig, axes = plt.subplots(2, 1, figsize=(9, 6), sharex=True)
    width = 0.38
    for ax, key, ylabel in ((axes[0], "cs_per_s", "Context switches / s"), (axes[1], "in_per_s", "Interrupts / s")):
        for k, (rt, _) in enumerate(RUNTIMES):
            ys = []
            for p in profiles:
                v = [r["vmstat"][key] for r in ffi_runs(data, rt, p) if r.get("vmstat")]
                ys.append(st.mean(v) if v else 0)
            xs = [i + (k - 0.5) * (width + 0.02) for i in range(len(profiles))]
            ax.bar(xs, ys, width=width, color=COLOR[rt], edgecolor=SURFACE, linewidth=1)
        ax.set_ylabel(ylabel)
        ax.set_yscale("log")
    axes[1].set_xticks(range(len(profiles)))
    axes[1].set_xticklabels([PROFILE_LABEL[p] for p in profiles], rotation=20, ha="right")
    axes[0].legend(handles=legend_handles(), loc="upper left")
    axes[0].set_title("Host activity during the cyclictest window (vmstat, mean of runs; log scale)")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "host_activity.png"), dpi=160)
    plt.close(fig)


COMPARE_COLOR = "#1baf7a"  # categorical slot 3, next to the runtimes' slots 1-2


def compare_runs(data, other, label, out, md):
    """Each runtime measured both here and in <other>: a table, and a
    figure with one panel per runtime (max latency per profile)."""
    profiles = ["baseline"] + [p for g in GROUPS.values() for p, _ in g]
    both = [(rt, name) for rt, name in RUNTIMES
            if any(ffi_runs(data, rt, p) for p in profiles) and any(ffi_runs(other, rt, p) for p in profiles)]
    if not both:
        return
    md.append("## %s vs this run (µs)\n" % label)
    md.append("| Profile | Runtime | n (%s / now) | Avg median | Max mean | Max worst |" % label)
    md.append("|---|---|---|---|---|---|")
    f = lambda runs, k, fn: ("%.1f" % fn([r[k] for r in runs])) if runs else "-"
    for p in profiles:
        for rt, _ in both:
            a, b = ffi_runs(other, rt, p), ffi_runs(data, rt, p)
            if not a and not b:
                continue
            md.append("| %s | %s | %d / %d | %s / %s | %s / %s | %s / %s |" % (
                p, "runc" if rt == "runc" else "runPHI-KVM", len(a), len(b),
                f(a, "avg_us", st.median), f(b, "avg_us", st.median),
                f(a, "max_us", st.mean), f(b, "max_us", st.mean), f(a, "max_us", max), f(b, "max_us", max)))
    md.append("")

    from matplotlib.patches import Patch
    fig, axes = plt.subplots(len(both), 1, figsize=(10, 4.2 * len(both)), sharex=True, squeeze=False)
    width, gap = 0.34, 0.04
    for ax, (rt, name) in zip(axes[:, 0], both):
        for k, (runs_of, color) in enumerate(((other, COMPARE_COLOR), (data, COLOR[rt]))):
            pos = [i + (k - 0.5) * (width + gap) for i in range(len(profiles))]
            vals = [[r["max_us"] for r in ffi_runs(runs_of, rt, p)] or [float("nan")] for p in profiles]
            ax.boxplot(vals, positions=pos, widths=width, patch_artist=True,
                       boxprops=dict(facecolor=color, edgecolor=color, alpha=0.9),
                       medianprops=dict(color=INK, linewidth=1.2),
                       whiskerprops=dict(color=color), capprops=dict(color=color),
                       flierprops=dict(marker="o", markersize=4, markerfacecolor="none", markeredgecolor=color))
        ax.set_ylabel("Max latency (µs)")
        ax.set_ylim(bottom=0)
        short = "runc" if rt == "runc" else "runPHI-KVM"
        ax.legend(handles=[Patch(facecolor=COMPARE_COLOR, label="%s, %s" % (short, label)),
                           Patch(facecolor=COLOR[rt], label="%s, this run" % short)], loc="upper left")
        ax.set_title("%s: maximum cyclictest latency per profile" % name)
    axes[-1, 0].set_xticks(range(len(profiles)))
    axes[-1, 0].set_xticklabels([PROFILE_LABEL[p] for p in profiles], rotation=20, ha="right")
    fig.tight_layout()
    fig.savefig(os.path.join(out, "comparison.png"), dpi=160)
    plt.close(fig)


def main():
    args = sys.argv[1:]
    compare = None
    if "--compare" in args:
        i = args.index("--compare")
        compare = args[i + 1:i + 3]
        del args[i:i + 3]
    if len(args) != 2 or (compare is not None and len(compare) != 2):
        raise SystemExit(__doc__)
    results, out = args
    os.makedirs(out, exist_ok=True)
    style()
    notes = []
    data = load(results, notes)
    md = ["# runPHI-KVM vs runc on the Kria KV260\n",
          "Campaigns found: " + ", ".join("%s (%d)" % (k, len(v)) for k, v in data.items()) + "\n"]
    if notes:
        md.append("Data checks:\n\n" + "\n".join("- " + n for n in notes) + "\n")
    js = {}
    lifecycle(data, out, md, js)
    ffi_tables(data, md, js)
    baseline_fig(data, out)
    for g in GROUPS:
        group_fig(data, out, g)
    host_activity_fig(data, out)
    if compare:
        cnotes = []
        other = load(compare[0], cnotes)
        md.extend("- %s: %s" % (compare[1], n) for n in cnotes)
        compare_runs(data, other, compare[1], out, md)
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(js, f, indent=1)
    print("\n".join(md))


if __name__ == "__main__":
    main()
