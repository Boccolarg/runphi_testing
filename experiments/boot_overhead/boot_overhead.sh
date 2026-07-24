#!/bin/bash
#*********************************************
# runPHI boot-overhead experiment: single-condition driver.
#
# Launches the probe container ITERATIONS times under one docker runtime
# and one cache policy (warm or cold), recording a host-side launch
# timestamp per iteration. Pair the resulting launch file with the
# container-written times file using analyze.sh.
#
# A "condition" is one cell of the experiment matrix:
#     {runphi, vanilla runc} x {warm cache, cold cache}
# run_suite.sh sweeps all four; use this script directly to re-run one.
#*********************************************

set -euo pipefail

# --- Defaults (override via flags) ----------------------------------------
ITERATIONS=51
RUNTIME=""                       # docker runtime name; "" => docker default
DROP_CACHES=0                    # 1 => cold cache (drop before each iter)
LABEL="run"
OUTDIR="./results"
IMAGE="ubuntu"
VOLUME="/root/container_volume"  # bind-mounted at /home; holds start.sh + times.txt
HOST_TIMER="/proc/timer_list"
RUN_SECONDS=5                    # let the container settle before stopping
GAP_SECONDS=3                    # spacing between iterations
CPU_RT_RUNTIME=950000            # 0 => omit --cpu-rt-runtime
LISTENER_FILE=""                 # path the runc_listener appends "CREATE ..." to;
                                 # if set, truncated before the run and archived after

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

usage() {
    cat <<EOF
Usage: $0 [options]

  -r, --runtime NAME     docker runtime to use (e.g. runphi | vanilla).
                         Empty uses the docker default runtime.
  -n, --iterations N     number of container launches (default: $ITERATIONS)
  -c, --drop-caches      cold-cache mode: sync + drop_caches before each iter
  -l, --label TAG        label for output files (default: $LABEL)
  -o, --outdir DIR       results directory (default: $OUTDIR)
      --image IMG        container image (default: $IMAGE)
      --volume DIR       host dir bind-mounted at /home (default: $VOLUME)
      --timer PATH       host monotonic clock file (default: $HOST_TIMER)
      --run-seconds S    settle time before stop (default: $RUN_SECONDS)
      --gap-seconds S    pause between iterations (default: $GAP_SECONDS)
      --no-cpu-rt        do not pass --cpu-rt-runtime
      --listener-file P  path the runc_listener appends to; when set, this
                         file is truncated before the run and archived as
                         \$OUTDIR/\$LABEL_create.txt for the runc-level metric
  -h, --help             show this help

Produces:
  \$OUTDIR/\$LABEL_launch.txt   host "LAUNCH <iter> <now_ns>" lines
  \$OUTDIR/\$LABEL_times.txt    copy of container "BOOTED <iter> <now_ns>" lines
  \$OUTDIR/\$LABEL_create.txt   listener "CREATE <cid> <now_ns>" lines (only if --listener-file)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--runtime)     RUNTIME="$2"; shift 2 ;;
        -n|--iterations)  ITERATIONS="$2"; shift 2 ;;
        -c|--drop-caches) DROP_CACHES=1; shift ;;
        -l|--label)       LABEL="$2"; shift 2 ;;
        -o|--outdir)      OUTDIR="$2"; shift 2 ;;
        --image)          IMAGE="$2"; shift 2 ;;
        --volume)         VOLUME="$2"; shift 2 ;;
        --timer)          HOST_TIMER="$2"; shift 2 ;;
        --run-seconds)    RUN_SECONDS="$2"; shift 2 ;;
        --gap-seconds)    GAP_SECONDS="$2"; shift 2 ;;
        --no-cpu-rt)      CPU_RT_RUNTIME=0; shift ;;
        --listener-file)  LISTENER_FILE="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ $DROP_CACHES -eq 1 && $EUID -ne 0 ]]; then
    echo "Cold-cache mode needs root (to write /proc/sys/vm/drop_caches)." >&2
    exit 1
fi

mkdir -p "$OUTDIR"
mkdir -p "$VOLUME"

# Stage the probe into the shared volume and the host's view of times.txt.
cp -f "$SCRIPT_DIR/start.sh" "$VOLUME/start.sh"
chmod +x "$VOLUME/start.sh"

launch_file="$OUTDIR/${LABEL}_launch.txt"
times_file="$VOLUME/times.txt"
: > "$launch_file"
: > "$times_file"
if [[ -n "$LISTENER_FILE" ]]; then
    : > "$LISTENER_FILE"
fi

# Pure-bash read of the host monotonic "now" (matches the in-container probe).
read_now() {
    local key _at val _unit
    while read -r key _at val _unit; do
        if [[ $key == now ]]; then
            echo "$val"
            return
        fi
    done < "$HOST_TIMER"
}

runtime_args=()
[[ -n "$RUNTIME" ]] && runtime_args=(--runtime "$RUNTIME")

cpu_rt_args=()
[[ "$CPU_RT_RUNTIME" -ne 0 ]] && cpu_rt_args=(--cpu-rt-runtime="$CPU_RT_RUNTIME")

echo "Condition '$LABEL': runtime='${RUNTIME:-<default>}', drop_caches=$DROP_CACHES, iterations=$ITERATIONS"

for i in $(seq 1 "$ITERATIONS"); do
    if [[ $DROP_CACHES -eq 1 ]]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches
    fi

    # Capture the host timestamp as the very last thing before launch.
    host_now=$(read_now)
    echo "LAUNCH $i $host_now" >> "$launch_file"

    cid=$(docker run --rm -d -i -t \
        "${runtime_args[@]}" \
        --name "boot_test_$i" \
        "${cpu_rt_args[@]}" \
        -v "$VOLUME:/home" \
        --privileged \
        -v "${HOST_TIMER}:/host_timer_list:ro" \
        -e "RUN_ID=$i" \
        "$IMAGE" bash /home/start.sh)

    sleep "$RUN_SECONDS"
    docker stop "$cid" >/dev/null 2>&1 || true
    sleep "$GAP_SECONDS"
    echo "  iteration $i done"
done

# Archive the container-written times alongside the launch file.
cp -f "$times_file" "$OUTDIR/${LABEL}_times.txt"
echo "Wrote $launch_file and $OUTDIR/${LABEL}_times.txt"
if [[ -n "$LISTENER_FILE" && -r "$LISTENER_FILE" ]]; then
    cp -f "$LISTENER_FILE" "$OUTDIR/${LABEL}_create.txt"
    echo "Wrote $OUTDIR/${LABEL}_create.txt"
fi
