#!/bin/sh
# analyze.sh [times.txt] - pair CREATE/BOOTED records by container id,
# report boot-time statistics in microseconds.

LOGFILE="${1:-/root/container_volume/times.txt}"

awk '
$1 == "CREATE" { c[$2] = $3; next }
$1 == "BOOTED" { b[$2] = $3; next }
END {
    n = 0; unpaired = 0
    for (id in b) {
        if (!(id in c)) { unpaired++; continue }
        d = (b[id] - c[id]) / 1000.0        # ns -> us
        v[++n] = d; sum += d
    }
    if (n == 0) { print "no paired samples"; exit 1 }

    # insertion sort (busybox awk has no asort)
    for (i = 2; i <= n; i++) {
        x = v[i]; j = i - 1
        while (j > 0 && v[j] > x) { v[j+1] = v[j]; j-- }
        v[j+1] = x
    }

    mean = sum / n
    for (i = 1; i <= n; i++) { dv = v[i] - mean; ss += dv * dv }
    sd = (n > 1) ? sqrt(ss / (n - 1)) : 0

    printf "samples   : %d (%d unpaired)\n", n, unpaired
    printf "min       : %10.1f us\n", v[1]
    printf "mean      : %10.1f us\n", mean
    printf "median    : %10.1f us\n", v[int(0.50 * (n-1)) + 1]
    printf "p99       : %10.1f us\n", v[int(0.99 * (n-1)) + 1]
    printf "max       : %10.1f us\n", v[n]
    printf "stddev    : %10.1f us\n", sd
}' "$LOGFILE"
