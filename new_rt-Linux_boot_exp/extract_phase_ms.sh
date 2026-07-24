#!/bin/sh
# extract_phase_ms.sh [-p PHASE] [times.txt] - print one latency per line, in
# whole milliseconds and with no unit, for a chosen container-lifecycle phase;
# ready to paste into a violin/box plot. Records are paired by 12-char id, output
# in run order, and containers missing a needed record are skipped. Basic
# arithmetic only, so it runs under busybox awk on the board as well.
#
#   ./extract_phase_ms.sh -p start-booted times.txt > start_booted_ms.txt

usage() {
    cat <<'EOF'
usage: extract_phase_ms.sh [-p PHASE] [times.txt]
  PHASE (default create-booted):
    create-booted   BOOTED - CREATE   full boot (same as extract_boot_ms.sh)
    create-start    START  - CREATE   runtime/setup latency  (needs -s on runs)
    start-booted    BOOTED - START    process-launch latency (needs -s on runs)
EOF
}

PHASE=create-booted
while getopts "p:h" opt; do
    case "$opt" in
        p) PHASE=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
LOGFILE="${1:-/root/container_volume/times.txt}"

case "$PHASE" in
    create-booted) A=CREATE; B=BOOTED ;;
    create-start)  A=CREATE; B=START  ;;
    start-booted)  A=START;  B=BOOTED ;;
    *) echo "invalid -p: $PHASE" >&2; usage >&2; exit 2 ;;
esac

# A-record stored per id; on the matching B-record, emit (B - A) rounded to ms.
awk -v A="$A" -v B="$B" '
    $1 == A { t[$2] = $3 }
    $1 == B && ($2 in t) { printf "%d\n", int(($3 - t[$2]) / 1000000.0 + 0.5) }
' "$LOGFILE"
