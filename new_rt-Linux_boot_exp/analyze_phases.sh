#!/bin/sh
# analyze_phases.sh [times.txt] - like analyze.sh, but for logs that also contain
# START records (from `boot_bench.sh -s on`). Reports min/mean/median/p99/max/
# stddev in MICROSECONDS for each container-lifecycle phase:
#
#     create->start    START  - CREATE    runtime/setup latency
#     start->booted    BOOTED - START     process-launch latency
#     create->booted   BOOTED - CREATE    full boot (same as analyze.sh)
#
# Records are paired by 12-char id. A phase with no data (e.g. a plain log with no
# START lines) is shown as n=0, so this also works on ordinary times.txt files.
# Self-contained (Newton's-method sqrt), so it runs under busybox awk on the board
# as well as on the dev box.

LOGFILE="${1:-/root/container_volume/times.txt}"

awk '
function isqrt(x,   g, i) {                     # busybox awk has no sqrt()
    if (x <= 0) return 0
    g = x
    for (i = 0; i < 100; i++) g = (g + x / g) / 2.0
    return g
}
function report(label, A, B,   id, v, n, i, j, x, sum, mean, ss, sd) {
    n = 0; sum = 0; ss = 0
    for (id in B) if (id in A) { v[++n] = (B[id] - A[id]) / 1000.0; sum += v[n] }
    if (n == 0) { printf "%-14s  n=0 (no paired samples)\n", label; return }
    for (i = 2; i <= n; i++) {                  # insertion sort (no asort in busybox)
        x = v[i]; j = i - 1
        while (j > 0 && v[j] > x) { v[j+1] = v[j]; j-- }
        v[j+1] = x
    }
    mean = sum / n
    for (i = 1; i <= n; i++) ss += (v[i] - mean) * (v[i] - mean)
    sd = (n > 1) ? isqrt(ss / (n - 1)) : 0
    printf "%-14s  n=%-4d min=%10.1f mean=%10.1f median=%10.1f p99=%10.1f max=%10.1f stddev=%9.1f\n",
        label, n, v[1], mean, v[int(0.50*(n-1))+1], v[int(0.99*(n-1))+1], v[n], sd
}
$1 == "CREATE" { c[$2] = $3; next }
$1 == "START"  { s[$2] = $3; next }
$1 == "BOOTED" { b[$2] = $3; next }
END {
    print "phase latencies (microseconds):"
    report("create->start",  c, s)
    report("start->booted",  s, b)
    report("create->booted", c, b)
}
' "$LOGFILE"
