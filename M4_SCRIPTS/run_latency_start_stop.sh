#!/usr/bin/env bash
# ==============================================================================
# M4 Campaign 1: Lifecycle Start/Stop Latency (runPHI vs runc)
# With Host Telemetry (vmstat)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results_lifecycle"
mkdir -p "$RESULTS_DIR"

ISOLATED_CPU=3
NOISE_CPUS="0-2"
REPS=${REPS:-30}
CSV_OUT="$RESULTS_DIR/lifecycle_latency.csv"

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
    echo -e "\033[1;32m[LIFECYCLE-BENCH]\033[0m $(date '+%H:%M:%S') - $*"
}

command -v docker >/dev/null 2>&1 || { echo "Docker non trovato." >&2; exit 1; }
command -v vmstat >/dev/null 2>&1 || { echo "vmstat non trovato." >&2; exit 1; }

export LC_ALL=C
export LC_NUMERIC=C

TARGET_MODE="${1:-}"
if [ -n "$TARGET_MODE" ] && [ "$TARGET_MODE" != "all" ]; then
    MODES=("$TARGET_MODE")
else
    MODES=("cold" "warm")
fi

if [ ! -f "$CSV_OUT" ]; then
    echo "iteration,runtime,cache_mode,create_ms,start_ms,stop_ms,rm_ms,total_ms" > "$CSV_OUT"
fi
log "Avvio Campagna 1: Lifecycle Latency ($REPS ripetizioni)..."

for mode in "${MODES[@]}"; do
    log "Esecuzione benchmark in modalità cache: $mode"
    if [ -f "$CSV_OUT" ]; then
        grep -v ",$mode," "$CSV_OUT" > "$CSV_OUT.tmp" || true
        mv "$CSV_OUT.tmp" "$CSV_OUT"
    fi
    for ((i=1; i<=REPS; i++)); do
        for runtime in "runc" "runphi"; do
            
            if [ "$mode" = "cold" ]; then
                sync
                echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
            fi

            VMSTAT_OUT="$RESULTS_DIR/vmstat_${runtime}_${mode}_run${i}.txt"
            taskset -c "$NOISE_CPUS" vmstat -t 1 > "$VMSTAT_OUT" 2>&1 &
            VMSTAT_PID=$!

            IMAGE=$(get_image "$runtime")

            t0=$(date +%s%N)
            cid=$(docker create --runtime="$runtime" "${COMMON_DOCKER_FLAGS[@]}" "$IMAGE" "${CYCLICTEST_CMD[@]}")
            t1=$(date +%s%N)

            t2=$(date +%s%N)
            docker start "$cid" > /dev/null
            t3=$(date +%s%N)

            sleep 1

            t4=$(date +%s%N)
            docker stop -t 10 "$cid" > /dev/null
            t5=$(date +%s%N)

            t6=$(date +%s%N)
            docker rm "$cid" > /dev/null
            t7=$(date +%s%N)

            if [ -n "$VMSTAT_PID" ] && kill -0 "$VMSTAT_PID" 2>/dev/null; then
                kill -TERM "$VMSTAT_PID" 2>/dev/null || true
                wait "$VMSTAT_PID" 2>/dev/null || true
            fi
            VMSTAT_PID=""

            create_ms=$(awk "BEGIN {printf \"%.4f\", ($t1 - $t0) / 1000000}")
            start_ms=$(awk "BEGIN {printf \"%.4f\", ($t3 - $t2) / 1000000}")
            stop_ms=$(awk "BEGIN {printf \"%.4f\", ($t5 - $t4) / 1000000}")
            rm_ms=$(awk "BEGIN {printf \"%.4f\", ($t7 - $t6) / 1000000}")
            total_ms=$(awk "BEGIN {printf \"%.4f\", $create_ms + $start_ms + $stop_ms + $rm_ms}")

            echo "$i,$runtime,$mode,$create_ms,$start_ms,$stop_ms,$rm_ms,$total_ms" >> "$CSV_OUT"
            log "  [$runtime][$mode] Run $i/$REPS: create=${create_ms}ms, start=${start_ms}ms, stop=${stop_ms}ms, rm=${rm_ms}ms"
        done
    done
done

log "Campagna completata. Dati salvati in: $CSV_OUT"