#!/bin/bash
# stressor.sh
#
# Runs the TACLeBench suite once per interference configuration: first a
# baseline with an idle root cell, then one run per stress-ng stressor.
#
# For each configuration:
#   1. Start stress-ng in the root cell (skipped for the baseline).
#   2. Wait WAIT_FOR_STABILIZATION seconds.
#   3. Run BENCH_SCRIPT, writing straight into <config>_raw.
#   4. Stop stress-ng and pause before the next configuration.
#
# Results land in $RESULTS_DIR_BASE/<config>_raw/results_<bench>.bin.txt, which
# is the layout extract_time.sh expects (it turns every *_raw directory into a
# sibling directory of per-benchmark times).
#
# The stressors run on the root cell's CPUs 0-2 while the inmate owns CPU 3.
# This relies on the kernel being booted with "isolcpus=domain,managed_irq,3":
# with the earlier "2-3" the scheduler would never place load on CPU 2, since
# isolcpus=domain takes it out of every scheduling domain and an affinity mask
# alone does not bring it back.

# "baseline" means no stressor at all; the rest are stress-ng <type><workers>.
CONFIGS=("baseline" "fork8" "memcpy8" "open8" "udp8" "cpu8")

BENCH_SCRIPT="/root/taclebench/workdirs/APU_jailhouse/external_script_shmem.sh"
RESULTS_DIR_BASE="/root/taclebench/results/APU_jailhouse/shmem"
LOG_DIR="${RESULTS_DIR_BASE}/logs"
WAIT_FOR_STABILIZATION=10
STRESS_TIMEOUT=10h

BENCH_ARGS=("$@")

mkdir -p "$RESULTS_DIR_BASE" "$LOG_DIR"

EXPECTED_CPUS="0-2"
ACTUAL_CPUS=$(grep Cpus_allowed_list /proc/self/status | awk '{print $2}')
if [[ "$ACTUAL_CPUS" != "$EXPECTED_CPUS" ]]; then
    echo "WARNING: this shell may use CPUs $ACTUAL_CPUS, expected $EXPECTED_CPUS."
    echo "         Check that the kernel was booted with isolcpus=domain,managed_irq,3;"
    echo "         otherwise the stressors will not load all three root-cell CPUs."
fi

# cpufreq resets on every boot and this kernel only has the userspace governor,
# so /root/max_perf.sh must be run after each reboot, before any measurement.
for c in 0 1 2 3; do
    d=/sys/devices/system/cpu/cpu$c/cpufreq
    [[ -d $d ]] || continue
    cur=$(cat "$d/scaling_cur_freq" 2>/dev/null)
    hwmax=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
    if [[ -n "$cur" && -n "$hwmax" && "$cur" != "$hwmax" ]]; then
        echo "WARNING: cpu$c runs at $cur Hz, hardware maximum is $hwmax Hz."
        echo "         Run /root/max_perf.sh before benchmarking."
    fi
done

echo "Start: $(date)"
echo "Configurations: ${CONFIGS[*]}"

for config in "${CONFIGS[@]}"; do
    echo "================================================"
    echo "Configuration: $config   ($(date))"

    RESULTS_DIR="${RESULTS_DIR_BASE}/${config}_raw"
    mkdir -p "$RESULTS_DIR"

    STRESS_PID=""
    if [[ "$config" != "baseline" ]]; then
        stress_type=$(sed -E 's/([a-z]+)[0-9]+/\1/' <<< "$config")
        stress_count=$(sed -E 's/[a-z]+([0-9]+)/\1/' <<< "$config")

        stress-ng --"$stress_type" "$stress_count" --timeout "$STRESS_TIMEOUT" \
            > "${LOG_DIR}/stress_${config}.log" 2>&1 &
        STRESS_PID=$!
        echo "Started stress-ng --$stress_type $stress_count (PID $STRESS_PID)"

        echo "Waiting $WAIT_FOR_STABILIZATION seconds for system stabilization..."
        sleep "$WAIT_FOR_STABILIZATION"

        if ! kill -0 "$STRESS_PID" 2>/dev/null; then
            echo "ERROR: stress-ng died before the run started, see ${LOG_DIR}/stress_${config}.log" >&2
        fi
    else
        echo "No stressor: baseline run."
        sleep "$WAIT_FOR_STABILIZATION"
    fi

    echo "Running benchmarks into $RESULTS_DIR ..."
    # tee rather than redirect, so a `screen -r` shows live per-benchmark progress
    # while the full transcript still lands in the log.
    "$BENCH_SCRIPT" -o "$RESULTS_DIR" "${BENCH_ARGS[@]}" 2>&1 \
        | tee "${LOG_DIR}/bench_${config}.log"
    BENCH_EXIT=${PIPESTATUS[0]}
    if [[ $BENCH_EXIT -ne 0 ]]; then
        echo "ERROR: benchmark script exited with code $BENCH_EXIT, see ${LOG_DIR}/bench_${config}.log" >&2
    fi
    echo "Collected $(ls "$RESULTS_DIR" | wc -l) result files."

    if [[ -n "$STRESS_PID" ]]; then
        echo "Stopping stress-ng (PID $STRESS_PID)..."
        kill -TERM "$STRESS_PID" 2>/dev/null
        sleep 2
        if kill -0 "$STRESS_PID" 2>/dev/null; then
            echo "stress-ng is still running, sending SIGKILL..."
            kill -KILL "$STRESS_PID" 2>/dev/null
        fi
        wait "$STRESS_PID" 2>/dev/null
        # stress-ng spawns workers that may outlive the parent
        pkill -KILL stress-ng 2>/dev/null
        echo "Stressor $config finished."
    fi

    sleep "$WAIT_FOR_STABILIZATION"
done

echo "================================================"
echo "All configurations processed at $(date)."
echo
echo "Summary:"
for config in "${CONFIGS[@]}"; do
    d="${RESULTS_DIR_BASE}/${config}_raw"
    n=$(ls "$d" 2>/dev/null | wc -l)
    empty=$(find "$d" -type f -empty 2>/dev/null | wc -l)
    echo "  ${config}_raw: $n files, $empty empty"
done
