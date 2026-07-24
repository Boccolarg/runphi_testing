#!/bin/bash
#*********************************************
# runPHI boot-overhead experiment: suite runner.
#
# Sweeps the 2x2 matrix
#       {vanilla runc, runphi} x {warm cache, cold cache}
# collecting raw boot timestamps for each condition. The boot-time
# overhead runPHI's forwarding adds for a standard (non-runPHI) container
# is then, per cache regime:
#
#     overhead_warm = mean(runphi_warm) - mean(vanilla_warm)
#     overhead_cold = mean(runphi_cold) - mean(vanilla_cold)
#
# Collection is pure bash and runs fine on the minimal board userland.
# Analysis (analyze.py) needs python3 with no extra packages; it can run
# here if python3 is present, or off-board on a workstation:
#     analyze.py --dir <OUTDIR>
# (see analyze_remote.sh to pull a board run to your machine).
#
# Two measurement modes:
#   - runc-level (default): t0 is captured by /usr/local/sbin/runc_listener
#     when runc is invoked, excluding docker CLI + dockerd + containerd +
#     shim startup cost. Cleaner signal; matches earlier runphi experiments.
#   - end-to-end (--end-to-end): t0 is the host monotonic clock just before
#     `docker run`, so the measured interval includes the docker stack
#     startup. Matches what a user perceives as boot time.
#
# Prerequisite: four docker runtimes registered in /etc/docker/daemon.json
# (see README.md):
#     "runphi"            -> /usr/bin/runc                 (= runPHI)
#     "vanilla"           -> /usr/local/sbin/runc_vanilla
#     "runphi_listened"   -> runc_listener  -> runphi
#     "vanilla_listened"  -> runc_listener  -> runc_vanilla
# Only the *_listened pair is required for the default mode.
#*********************************************

set -euo pipefail

ITERATIONS=51
WARMUP=1
OUTDIR="./results/$(date +%Y%m%d-%H%M%S)"
# Default to listener mode (runc-level metric).
RUNPHI_RUNTIME="runphi_listened"
VANILLA_RUNTIME="vanilla_listened"
LISTENER_FILE="/tmp/runc_listener_create.txt"
END_TO_END=0
SKIP_COLD=0
COLLECT_ONLY=0
EXTRA=()                  # forwarded to boot_overhead.sh (e.g. --no-cpu-rt --image ...)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

usage() {
    cat <<EOF
Usage: $0 [options] [-- <extra boot_overhead.sh args>]

  -n, --iterations N      launches per condition (default: $ITERATIONS)
  -w, --warmup N          warmup iterations discarded in analysis (default: $WARMUP)
  -o, --outdir DIR        results directory (default: timestamped under ./results)
      --runphi-runtime N  docker runtime name for runPHI arm (default: $RUNPHI_RUNTIME)
      --vanilla-runtime N docker runtime name for vanilla arm (default: $VANILLA_RUNTIME)
      --listener-file P   listener output path (default: $LISTENER_FILE)
      --end-to-end        end-to-end mode: t0 is host clock before \`docker run\`;
                          uses bare 'runphi'/'vanilla' runtimes; no listener file
      --warm-only         skip the cold-cache (drop_caches) conditions
      --collect-only      only collect raw data; do not run analyze.py
  -h, --help              show this help

Anything after -- is passed through to boot_overhead.sh, e.g.:
  $0 -n 100 -- --no-cpu-rt --image debian --volume /root/cvol

On a minimal board, collect here and analyze elsewhere:
  ./run_suite.sh --collect-only -n 51          # on the board
  # then on your workstation:
  ./analyze_remote.sh root@<board> /root/boot_overhead/results/<dir>
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--iterations)     ITERATIONS="$2"; shift 2 ;;
        -w|--warmup)         WARMUP="$2"; shift 2 ;;
        -o|--outdir)         OUTDIR="$2"; shift 2 ;;
        --runphi-runtime)    RUNPHI_RUNTIME="$2"; shift 2 ;;
        --vanilla-runtime)   VANILLA_RUNTIME="$2"; shift 2 ;;
        --listener-file)     LISTENER_FILE="$2"; shift 2 ;;
        --end-to-end)        END_TO_END=1; shift ;;
        --warm-only)         SKIP_COLD=1; shift ;;
        --collect-only)      COLLECT_ONLY=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ $SKIP_COLD -eq 0 && $EUID -ne 0 ]]; then
    echo "Cold-cache conditions need root. Re-run as root or pass --warm-only." >&2
    exit 1
fi

# --end-to-end overrides the listener defaults: bare runtimes, no listener.
if [[ $END_TO_END -eq 1 ]]; then
    RUNPHI_RUNTIME="runphi"
    VANILLA_RUNTIME="vanilla"
    LISTENER_FILE=""
    echo "Mode: end-to-end (t0 = host clock before \`docker run\`)"
else
    echo "Mode: runc-level via $LISTENER_FILE (t0 = runc \"create\" invocation)"
fi

mkdir -p "$OUTDIR"

# run_condition <label> <runtime> <drop_caches:0|1>
run_condition() {
    local label="$1" runtime="$2" drop="$3"
    local drop_flag=()
    [[ "$drop" -eq 1 ]] && drop_flag=(--drop-caches)
    local listener_flag=()
    [[ -n "$LISTENER_FILE" ]] && listener_flag=(--listener-file "$LISTENER_FILE")

    echo "=== Condition: $label ==="
    "$SCRIPT_DIR/boot_overhead.sh" \
        --runtime "$runtime" \
        --iterations "$ITERATIONS" \
        --label "$label" \
        --outdir "$OUTDIR" \
        "${drop_flag[@]}" \
        "${listener_flag[@]}" \
        "${EXTRA[@]}"
}

run_condition "vanilla_warm" "$VANILLA_RUNTIME" 0
run_condition "runphi_warm"  "$RUNPHI_RUNTIME"  0
if [[ $SKIP_COLD -eq 0 ]]; then
    run_condition "vanilla_cold" "$VANILLA_RUNTIME" 1
    run_condition "runphi_cold"  "$RUNPHI_RUNTIME"  1
fi

echo
echo "Collection complete. Raw data in: $OUTDIR"

# --- Analysis (optional; needs python3) -----------------------------------
if [[ $COLLECT_ONLY -eq 1 ]]; then
    echo "--collect-only: skipping analysis. Analyze with:"
    echo "  analyze.py --dir $OUTDIR --warmup $WARMUP"
    exit 0
fi

if command -v python3 >/dev/null 2>&1; then
    echo
    python3 "$SCRIPT_DIR/analyze.py" --dir "$OUTDIR" --warmup "$WARMUP"
else
    echo "python3 not found; raw data collected. Analyze elsewhere with:"
    echo "  analyze.py --dir <copied $OUTDIR> --warmup $WARMUP"
fi
