#!/bin/bash
# run_benchmarks_with_stress.sh
#
# This script automates running the benchmark script while applying stress-ng stressors.
# It iterates over the following stressors: cpu8, fork8, memcpy8, open8, udp8.
#
# For each stressor:
#   1. Start stress-ng with a 10-hour timeout in the background.
#   2. Wait for a specified number of seconds (WAIT_FOR_STABILIZATION) for system stabilization.
#   3. Execute BENCH_SCRIPT (passing any arguments given to this script).
#   4. Stop the stress-ng process.
#   5. Move the results from RESULTS_DIR_BASE to NEW_RESULTS_DIR.
#   6. Proceed to the next stressor.

# List of stressors
stressors=("fork8" "memcpy8" "open8" "udp8" "cpu8")

# Path to the benchmark script
BENCH_SCRIPT="/root/taclebench/workdirs/APU_jailhouse/external_script_shmem.sh"

# Base directory where benchmark results are stored
RESULTS_DIR_BASE="/root/taclebench/results/APU_jailhouse/shmem"

# Wait time (in seconds) for system stabilization after starting stress-ng and between runs
WAIT_FOR_STABILIZATION=10

# Capture all arguments passed to this script
BENCH_ARGS=("$@")

for stress in "${stressors[@]}"; do
    echo "================================================"
    echo "Starting stressor: $stress"

    # Extract stressor type and count (e.g., "cpu8" => type=cpu, count=8)
    stress_type=$(echo "$stress" | sed -E 's/([a-z]+)[0-9]+/\1/')
    stress_count=$(echo "$stress" | sed -E 's/[a-z]+([0-9]+)/\1/')

    # Launch stress-ng with a 10-hour timeout in the background.
    stress-ng --"$stress_type" "$stress_count" --timeout 10h &
    STRESS_PID=$!
    echo "Started stress-ng (PID $STRESS_PID) for stressor $stress"

    echo "Waiting $WAIT_FOR_STABILIZATION seconds for system stabilization..."
    sleep "$WAIT_FOR_STABILIZATION"

    echo "Running benchmark script with arguments: ${BENCH_ARGS[*]}"
    # Forward all script arguments to BENCH_SCRIPT
    "$BENCH_SCRIPT" "${BENCH_ARGS[@]}"
    BENCH_EXIT=$?
    if [ $BENCH_EXIT -ne 0 ]; then
        echo "ERROR: Benchmark script exited with code $BENCH_EXIT"
    fi

    echo "Stopping stress-ng (PID $STRESS_PID)..."
    kill -TERM $STRESS_PID
    sleep 2
    # If it's still alive, send SIGKILL
    if ps -p $STRESS_PID > /dev/null 2>&1; then
        echo "stress-ng is still running, sending SIGKILL..."
        kill -KILL $STRESS_PID
    fi
    wait $STRESS_PID 2>/dev/null
    echo "Stressor $stress finished."

    # Rename/move results to preserve them for this stress run
    if [ -d "$RESULTS_DIR_BASE" ]; then
        NEW_RESULTS_DIR="${RESULTS_DIR_BASE}/${stress}"
        mkdir -p "$NEW_RESULTS_DIR" || {
            echo "ERROR: Failed to create directory $NEW_RESULTS_DIR"
            continue
        }

        # Check if any result files exist before moving
        if ls "${RESULTS_DIR_BASE}/results_"* > /dev/null 2>&1; then
            mv "${RESULTS_DIR_BASE}/results_"* "$NEW_RESULTS_DIR/" || {
                echo "ERROR: Failed to move results to $NEW_RESULTS_DIR"
            }
            echo "Results moved to $NEW_RESULTS_DIR"
        else
            echo "WARNING: No results files found in $RESULTS_DIR_BASE"
        fi
    else
        echo "WARNING: Results directory $RESULTS_DIR_BASE does not exist."
    fi

    # Optional pause between stressor runs
    sleep "$WAIT_FOR_STABILIZATION"
done

echo "================================================"
echo "All stressors processed."