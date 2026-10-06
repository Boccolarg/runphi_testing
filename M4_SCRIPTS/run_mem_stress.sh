#!/usr/bin/env bash
# ==============================================================================
# M4 Campaign 3: Noisy Neighbor - Memory Stress (runPHI vs runc)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results_mem"
mkdir -p "$RESULTS_DIR"

ISOLATED_CPU=3
NOISE_CPUS="0-2"
REPS=30
STRESS_DURATION="60s"
CSV_OUT="$RESULTS_DIR/mem_stress_degradation_data.csv"

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

STRESS_PID=""
VMSTAT_PID=""

cleanup() {
    echo -e "\n[ABORT] Interruzione rilevata, pulizia processi..."
    if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
        kill -9 "$STRESS_PID" 2>/dev/null || true
    fi
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
    echo -e "\033[1;32m[STRESS-BENCH]\033[0m $(date '+%H:%M:%S') - $*"
}

command -v docker >/dev/null 2>&1 || { echo "Docker non trovato." >&2; exit 1; }
command -v stress-ng >/dev/null 2>&1 || { echo "stress-ng non trovato." >&2; exit 1; }
# Support single profile execution via argument (e.g. ./run_mem_stress.sh memcpy)
TARGET_PROFILE="${1:-}"
if [ -n "$TARGET_PROFILE" ] && [ "$TARGET_PROFILE" != "all" ]; then
    PROFILES=("$TARGET_PROFILE")
else
    PROFILES=("memcpy" "tlb_shootdown" "stream")
fi

if [ ! -f "$CSV_OUT" ]; then
    echo "iteration,runtime,stress_profile,min_us,avg_us,max_us" > "$CSV_OUT"
fi

for profile in "${PROFILES[@]}"; do
    log "Avvio profilo di disturbo Memoria: $profile"

    # Remove previous entries for this profile if re-running, avoiding duplicate rows
    if [ -f "$CSV_OUT" ]; then
        grep -v ",$profile," "$CSV_OUT" > "$CSV_OUT.tmp" || true
        mv "$CSV_OUT.tmp" "$CSV_OUT"
    fi

    for ((i=1; i<=REPS; i++)); do
        for runtime in "runc" "runphi"; do
            
            case "$profile" in
                "memcpy")
                    taskset -c "$NOISE_CPUS" stress-ng \
                        --memcpy 3 --vm-bytes 384M --vm-keep \
                        --timeout "$STRESS_DURATION" >/dev/null 2>&1 &
                    STRESS_PID=$!
                    ;;
                "tlb_shootdown")
                    taskset -c "$NOISE_CPUS" stress-ng \
                        --tlb-shootdown 3 \
                        --timeout "$STRESS_DURATION" >/dev/null 2>&1 &
                    STRESS_PID=$!
                    ;;
                "stream")
                    taskset -c "$NOISE_CPUS" stress-ng \
                        --stream 3 \
                        --timeout "$STRESS_DURATION" >/dev/null 2>&1 &
                    STRESS_PID=$!
                    ;;
            esac

            VMSTAT_OUT="$RESULTS_DIR/vmstat_${runtime}_${profile}_run${i}.txt"
            taskset -c "$NOISE_CPUS" vmstat -t 1 > "$VMSTAT_OUT" 2>&1 &
            VMSTAT_PID=$!

            sleep 2
            log "[$runtime][$profile] Run $i/$REPS (stress PID: $STRESS_PID, vmstat PID: $VMSTAT_PID)..."
            HIST_OUT="$RESULTS_DIR/hist_${runtime}_${profile}_run${i}.txt"
            IMAGE=$(get_image "$runtime")

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

            MIN=$(echo "$RAW_LOG" | grep -oP '(?:Min:|# Min Latencies:)\s*0*\K[0-9]+' | head -n 1 || echo 0)
            AVG=$(echo "$RAW_LOG" | grep -oP '(?:Avg:|# Avg Latencies:)\s*0*\K[0-9]+' | head -n 1 || echo 0)
            MAX=$(echo "$RAW_LOG" | grep -oP '(?:Max:|# Max Latencies:)\s*0*\K[0-9]+' | head -n 1 || echo 0)

            echo "$i,$runtime,$profile,$MIN,$AVG,$MAX" >> "$CSV_OUT"
            log "   -> Risultati: Min=${MIN}us, Avg=${AVG}us, Max=${MAX}us"

            if [ -n "$VMSTAT_PID" ] && kill -0 "$VMSTAT_PID" 2>/dev/null; then
                kill -TERM "$VMSTAT_PID" 2>/dev/null || true
                wait "$VMSTAT_PID" 2>/dev/null || true
            fi
            VMSTAT_PID=""

            if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
                kill -TERM "$STRESS_PID" 2>/dev/null || true
                wait "$STRESS_PID" 2>/dev/null || true
            fi
            STRESS_PID=""

            sleep 1
        done
    done
done

log "Campagna memoria completata. Risultati in: $CSV_OUT"