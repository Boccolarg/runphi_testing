#!/usr/bin/env python3
"""runPHI boot-overhead experiment: analyzer.

Reports up to two metrics per condition, in milliseconds:

* **runc-level** (``boot_now - create_now``): t0 is the moment runc receives
  the ``create`` verb, captured by ``/usr/local/sbin/runc_listener``. Excludes
  docker CLI + dockerd + containerd + shim startup. Cleaner signal; this is
  the default metric when ``<label>_create.txt`` is present in the dir.
* **end-to-end** (``boot_now - host_now``): t0 is the host monotonic clock
  read just before ``docker run``. Includes the whole docker stack startup.
  Matches what a user perceives as boot time.

Pure Python stdlib so it runs anywhere with python3 (including the board's
BusyBox userland, whose awk has no math support).

Usage:
    analyze.py --dir results/20260527-212050
    analyze.py --pair LAUNCH TIMES [--create CREATE] -l vanilla_warm

For a directory, conditions named ``{vanilla,runphi}_{warm,cold}``
additionally yield the forwarding-overhead lines.
"""

import argparse
import glob
import os
import sys


def read_launch(path):
    """iter -> host launch timestamp (ns)."""
    out = {}
    with open(path) as fh:
        for line in fh:
            f = line.split()
            if len(f) >= 3 and f[0] == "LAUNCH":
                out[int(f[1])] = int(f[2])
    return out


def read_times(path):
    """list of (iter, container timestamp ns), iter-sorted."""
    out = []
    with open(path) as fh:
        for line in fh:
            f = line.split()
            if len(f) >= 3 and f[0] == "BOOTED":
                out.append((int(f[1]), int(f[2])))
    out.sort()
    return out


def read_create(path):
    """list of (container_id, ns) in file order (one per create call)."""
    out = []
    with open(path) as fh:
        for line in fh:
            f = line.split()
            if len(f) >= 3 and f[0] == "CREATE":
                out.append((f[1], int(f[2])))
    return out


def deltas(launch_file, times_file, create_file, warmup):
    """Return two lists of (iter, delta_ms): runc-level and end-to-end.

    Iterations are serial within a condition: the i-th BOOTED (sorted by
    iter id) pairs with the i-th CREATE line in file order. End-to-end uses
    the iter-keyed LAUNCH map directly.
    """
    launch = read_launch(launch_file)
    times = read_times(times_file)            # sorted by iter
    creates = read_create(create_file) if create_file else []

    runc, e2e = [], []
    for pos, (it, boot_ns) in enumerate(times):
        if it <= warmup:
            continue
        if it in launch:
            d = (boot_ns - launch[it]) / 1e6
            if d >= 0:
                e2e.append((it, d))
        if creates and pos < len(creates):
            d = (boot_ns - creates[pos][1]) / 1e6
            if d >= 0:
                runc.append((it, d))
    if creates and len(creates) != len(times):
        print(f"  note: {os.path.basename(create_file)} has {len(creates)} "
              f"CREATE lines vs {len(times)} BOOTED - pairing by position",
              file=sys.stderr)
    return runc, e2e


def stats(values):
    """count, mean, median, sample-stddev, min, p95, max (all floats)."""
    n = len(values)
    if n == 0:
        return None
    v = sorted(values)
    mean = sum(v) / n
    var = sum((x - mean) ** 2 for x in v) / (n - 1) if n > 1 else 0.0
    stddev = var ** 0.5
    median = v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2
    rank = int(0.95 * n + 0.5)  # nearest-rank, matches the old awk version
    rank = min(max(rank, 1), n)
    p95 = v[rank - 1]
    return {
        "n": n, "mean": mean, "median": median, "stddev": stddev,
        "min": v[0], "p95": p95, "max": v[-1],
    }


def fmt_row(label, s):
    if s is None:
        return f"{label:<14} n=0    (no usable samples)"
    return (f"{label:<14} n={s['n']:<4d} mean={s['mean']:<9.3f} "
            f"median={s['median']:<9.3f} sd={s['stddev']:<8.3f} "
            f"min={s['min']:<8.3f} p95={s['p95']:<8.3f} max={s['max']:<8.3f}")


def print_table(title, label_to_stats):
    print(f"==================== {title} ====================")
    for label, s in label_to_stats:
        print(fmt_row(label, s))
    print("-" * (len(title) + 42))
    means = {label: s["mean"] for label, s in label_to_stats if s is not None}
    if "runphi_warm" in means and "vanilla_warm" in means:
        print(f"Forwarding overhead (warm cache): "
              f"{means['runphi_warm'] - means['vanilla_warm']:+.3f} ms")
    if "runphi_cold" in means and "vanilla_cold" in means:
        print(f"Forwarding overhead (cold cache): "
              f"{means['runphi_cold'] - means['vanilla_cold']:+.3f} ms")
    print("=" * (len(title) + 42))


def analyze_pair(launch_file, times_file, create_file, label, warmup, want_csv):
    runc, e2e = deltas(launch_file, times_file, create_file, warmup)
    if want_csv:
        print("iter,runc_ms,e2e_ms")
        runc_map = dict(runc)
        e2e_map = dict(e2e)
        for it in sorted(set(runc_map) | set(e2e_map)):
            r = f"{runc_map[it]:.3f}" if it in runc_map else ""
            e = f"{e2e_map[it]:.3f}" if it in e2e_map else ""
            print(f"{it},{r},{e}")
    return {
        "runc": stats([d for _, d in runc]),
        "e2e":  stats([d for _, d in e2e]),
    }


def analyze_dir(d, warmup, want_csv):
    rows = []
    for lf in sorted(glob.glob(os.path.join(d, "*_launch.txt"))):
        label = os.path.basename(lf)[: -len("_launch.txt")]
        tf = os.path.join(d, label + "_times.txt")
        cf = os.path.join(d, label + "_create.txt")
        if not os.path.exists(tf):
            continue
        rows.append((label, lf, tf, cf if os.path.exists(cf) else None))
    if not rows:
        sys.exit(f"No *_launch.txt / *_times.txt pairs found in {d}")

    # Canonical ordering when present; anything else trails alphabetically.
    order = {"vanilla_warm": 0, "runphi_warm": 1, "vanilla_cold": 2, "runphi_cold": 3}
    rows.sort(key=lambda r: (order.get(r[0], 99), r[0]))

    any_create = any(cf for _, _, _, cf in rows)
    runc_results, e2e_results = [], []
    for label, lf, tf, cf in rows:
        result = analyze_pair(lf, tf, cf, label, warmup, want_csv)
        runc_results.append((label, result["runc"]))
        e2e_results.append((label, result["e2e"]))

    if any_create:
        print_table("Boot time, runc-level metric (ms)", runc_results)
        print()
        print_table("Boot time, end-to-end metric (ms)", e2e_results)
    else:
        print_table("Boot time, end-to-end metric (ms)", e2e_results)


def main():
    ap = argparse.ArgumentParser(description="Analyze runPHI boot-overhead data.")
    ap.add_argument("--dir", help="results directory to analyze wholesale")
    ap.add_argument("--pair", nargs=2, metavar=("LAUNCH", "TIMES"),
                    help="analyze a single launch/times file pair")
    ap.add_argument("--create", metavar="CREATE",
                    help="optional CREATE file from runc_listener for --pair")
    ap.add_argument("-l", "--label", default="run", help="label for --pair output")
    ap.add_argument("-w", "--warmup", type=int, default=1,
                    help="discard the N earliest iterations (default: 1)")
    ap.add_argument("--csv", action="store_true",
                    help="also print per-iteration iter,runc_ms,e2e_ms rows")
    args = ap.parse_args()

    if args.dir:
        analyze_dir(args.dir, args.warmup, args.csv)
    elif args.pair:
        result = analyze_pair(args.pair[0], args.pair[1], args.create,
                              args.label, args.warmup, args.csv)
        if result["runc"] is not None:
            print(fmt_row(args.label + " runc", result["runc"]))
        if result["e2e"] is not None:
            print(fmt_row(args.label + " e2e", result["e2e"]))
    else:
        ap.error("provide --dir or --pair")


if __name__ == "__main__":
    main()
