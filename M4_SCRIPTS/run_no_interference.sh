#!/usr/bin/env bash
# ==============================================================================
# M4 Campaign 2: Steady-State Baseline Benchmark (Zero Interference)
# With Host Telemetry (vmstat) - runPHI vs runc
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results_steady"
mkdir -p "$RESULTS_DIR"

ISOLATED_CPU=3
NOISE_CPUS="0-2"
REPS=${REPS:-30}
CSV_OUT="$RESULTS_DIR/steadystate_summary.csv"

COMMON_DOCKER_FLAGS=(
    --cpuset-cpus="$ISOLATED_CPU"
    --memory=1024m
    --net=none
    --cap-add=SYS_NICE
    --ulimit rtprio=99
    --ulimit memlock=-1
)

CYCLICTEST_CMD=(
    cyclictest -p 99 -i 1000 -l 30000 -m -a "$ISOLATED_CPU" -q -h 1000
)

VMSTAT_PID=""

cleanup() {
    echo -e "\n[ABORT] Interruzione rilevata, pulizia processi..."
    if [ -n "$VMSTAT_PID" ] && kill -0 "$VMSTAT_PID" 2>/dev/null; then
        kill -9 "$VMSTAT_PID" 2>/dev/null || true
    fi
    exit 1
}
trap cleanup SIGINT SIGTERM

get_image() {
    local runtime="$1"
    if [ "$runtime" = "runphi" ]; then
        echo "rt-cyclictest:runphi"
    else
        docker image inspect rt-cyclictest:runc >/dev/null 2>&1 && echo "rt-cyclictest:runc" || echo "rt-cyclictest:docker"
    fi
}

log() {
    echo -e "\033[1;32m[STEADY-BENCH]\033[0m $(date '+%H:%M:%S') - $*"
}

command -v docker >/dev/null 2>&1 || { echo "Error: docker binary not found." >&2; exit 1; }
command -v vmstat >/dev/null 2>&1 || { echo "Error: vmstat binary not found." >&2; exit 1; }

echo "iteration,runtime,min_us,avg_us,max_us" > "$CSV_OUT"
log "Starting Campaign: Steady-State Jitter & Latency ($REPS repetitions, Zero Interference)..."

for ((i=1; i<=REPS; i++)); do
    for runtime in "runc" "runphi"; do
        
        # Telemetria confinata sui P-Core di housekeeping (0,2,4)
        VMSTAT_OUT="$RESULTS_DIR/vmstat_${runtime}_steady_run${i}.txt"
        taskset -c "$NOISE_CPUS" vmstat -t 1 > "$VMSTAT_OUT" 2>&1 &
        VMSTAT_PID=$!

        sleep 1
        log "[$runtime][steady] Run $i/$REPS (vmstat PID: $VMSTAT_PID)..."
        HIST_OUT="$RESULTS_DIR/hist_${runtime}_steady_run${i}.txt"
        IMAGE=$(get_image "$runtime")

        # Cyclictest su CPU 6
        if [ "$runtime" = "runc" ]; then
            RAW_LOG=$(docker run --rm \
                --runtime=runc \
                "${COMMON_DOCKER_FLAGS[@]}" \
                "$IMAGE" \
                "${CYCLICTEST_CMD[@]}")
        else
            CID=$(docker run -d \
                --runtime=runphi \
                "${COMMON_DOCKER_FLAGS[@]}" \
                "$IMAGE" \
                "${CYCLICTEST_CMD[@]}")

            docker wait "$CID" > /dev/null

            SHORT_ID="${CID:0:24}"
            LOG_FILE="/var/log/libvirt/qemu/runphi-${SHORT_ID}-serial.log"
            [ ! -f "$LOG_FILE" ] && LOG_FILE="/var/log/libvirt/qemu/runphi-${SHORT_ID}.log"
            RAW_LOG=$(sudo cat "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE" 2>/dev/null || echo "")
            docker rm "$CID" > /dev/null
        fi

        echo "$RAW_LOG" > "$HIST_OUT"

        if [ -n "$VMSTAT_PID" ] && kill -0 "$VMSTAT_PID" 2>/dev/null; then
            kill -TERM "$VMSTAT_PID" 2>/dev/null || true
            wait "$VMSTAT_PID" 2>/dev/null || true
        fi
        VMSTAT_PID=""

        MIN=$(echo "$RAW_LOG" | grep -oP '(?:Min:|# Min Latencies:)\s*0*\K[0-9]+' | head -n 1 || echo 0)
        AVG=$(echo "$RAW_LOG" | grep -oP '(?:Avg:|# Avg Latencies:)\s*0*\K[0-9]+' | head -n 1 || echo 0)
        MAX=$(echo "$RAW_LOG" | grep -oP '(?:Max:|# Max Latencies:)\s*0*\K[0-9]+' | head -n 1 || echo 0)

        echo "$i,$runtime,$MIN,$AVG,$MAX" >> "$CSV_OUT"
        log "   -> Results: Min=${MIN}us, Avg=${AVG}us, Max=${MAX}us"

        sleep 1
    done
done

log "Steady-State campaign completed successfully. Data saved to: $CSV_OUT"