#!/bin/sh
# extract_boot_ms.sh [times.txt] - print boot times, one per line, in whole
# milliseconds and with no unit, ready to paste into a plotting tool (violin/
# box plot, etc.):
#
#   ./extract_boot_ms.sh /root/container_volume/times.txt > boot_ms.txt
#
# Each row is BOOTED - CREATE for one container, paired by 12-char id (the same
# join analyze.sh uses); unpaired records are skipped. Values are emitted in run
# order (the order containers finished booting). Rounded to the nearest ms.
#
# Uses only +,-,*,/ and int(), so it runs under busybox awk on the board as well
# as on the dev host (unlike analyze.sh, whose sqrt() needs full math support).

LOGFILE="${1:-/root/container_volume/times.txt}"

awk '
    $1 == "CREATE" { c[$2] = $3; next }
    $1 == "BOOTED" && ($2 in c) {
        printf "%d\n", int(($3 - c[$2]) / 1000000.0 + 0.5)
    }
' "$LOGFILE"
