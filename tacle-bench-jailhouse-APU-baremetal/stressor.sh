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
#
# 4 workers, not the KV260 campaign's 8. With only 3 root-cell CPUs, 8 runnable
# hogs starved the RCU grace-period kthread hard enough to wedge CPU hotplug --
# and therefore `jailhouse cell create` -- for hours at a time. Interference here
# is bound by the 3 busy cores rather than by the worker count, so 4 saturates
# them just as thoroughly while leaving the root cell usable. Deviation from the
# KV260 configuration: recorded in the README.
CONFIGS=("baseline" "fork4" "memcpy4" "open4" "udp4" "cpu4")

BENCH_SCRIPT="/root/taclebench/workdirs/APU_jailhouse/external_script_shmem.sh"
RESULTS_DIR_BASE="/root/taclebench/results/APU_jailhouse/shmem"
LOG_DIR="${RESULTS_DIR_BASE}/logs"
WAIT_FOR_STABILIZATION=10

# Safety net only, against a leaked stress-ng: each configuration kills its own
# stressor explicitly when the benchmarks finish. It must comfortably exceed the
# longest configuration. This was 10h, which fork8 overran on 2026-07-29 —
# stress-ng exited cleanly at 36000s while 46 benchmarks were still to run, and
# they were recorded as stressed while nothing was stressing them. The bench
# script now also aborts if the stressor disappears (--require-pid).
STRESS_TIMEOUT=72h

# -r/--resume: skip configurations that are already complete and, within a
# configuration, benchmarks that already hold a full set of iterations. Makes the
# whole campaign restartable after a crash at the cost of at most one benchmark.
RESUME=""
BENCH_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--resume) RESUME=1; shift ;;
        # -c "open8 udp8": run only these configurations, in this order
        -c|--configs) read -r -a CONFIGS <<< "$2"; shift 2 ;;
        *) BENCH_ARGS+=("$1"); shift ;;
    esac
done
[[ -n "$RESUME" ]] && BENCH_ARGS+=("--resume")

ITERATIONS_EXPECTED=$(sed -n 's/^ITERATIONS=\([0-9]*\).*/\1/p' "$BENCH_SCRIPT" | head -1)
BIN_COUNT=$(find /root/taclebench/executables/APU_jailhouse/shmem -type f -name '*.bin' 2>/dev/null | wc -l)

# A configuration counts as done when every binary has a full result file.
config_is_complete() {
    local dir=$1 full=0 f n
    [[ -d $dir ]] || return 1
    for f in "$dir"/*.txt; do
        [[ -e $f ]] || continue
        n=$(wc -l < "$f")
        (( n == ITERATIONS_EXPECTED )) && full=$((full + 1))
    done
    (( full == BIN_COUNT && BIN_COUNT > 0 ))
}

mkdir -p "$RESULTS_DIR_BASE" "$LOG_DIR"

EXPECTED_CPUS="0-2"
ACTUAL_CPUS=$(grep Cpus_allowed_list /proc/self/status | awk '{print $2}')
if [[ "$ACTUAL_CPUS" != "$EXPECTED_CPUS" ]]; then
    echo "WARNING: this shell may use CPUs $ACTUAL_CPUS, expected $EXPECTED_CPUS."
    echo "         Check that the kernel was booted with isolcpus=domain,managed_irq,3;"
    echo "         otherwise the stressors will not load all three root-cell CPUs."
fi

# The deprecated cortex_edac driver polls per-CPU cache ECC registers every
# 100 ms via smp_call_function_any(). When that IPI targets the CPU Jailhouse has
# just taken for the inmate cell, the completion never arrives: the edac-poller
# kworker wedges forever, RCU grace periods stop advancing and the board hangs
# (rcu_sched self-detected stall, trace through cortex_arm64_edac_check). This
# killed two campaigns before it was diagnosed. Unbinding costs only L1/L2 ECC
# error reporting, and a reboot restores it.
EDAC_DRV=/sys/bus/platform/drivers/cortex_edac
if [[ -e "$EDAC_DRV/edac" ]]; then
    echo "Unbinding cortex_edac: its 100 ms per-CPU IPI poll deadlocks against Jailhouse CPU handover."
    if echo edac > "$EDAC_DRV/unbind" 2>/dev/null; then
        echo "  unbound."
    else
        echo "  WARNING: unbind failed. The run is likely to hang; investigate before trusting results." >&2
    fi
fi

# Elevate rcu_sched kthread priority to SCHED_FIFO 1 so RCU grace periods never get starved
# during CPU hotplug / jailhouse cell operations.
RCU_PID=$(ps | grep '[r]cu_sched' | awk 'NR==1{print $1}')
if [[ -n "$RCU_PID" ]]; then
    echo "Promoting rcu_sched (PID $RCU_PID) to SCHED_FIFO priority 1..."
    chrt -f -p 1 "$RCU_PID" 2>/dev/null && echo "  promoted." || echo "  WARNING: failed to elevate rcu_sched priority." >&2
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

    if [[ -n "$RESUME" ]] && config_is_complete "$RESULTS_DIR"; then
        echo "Already complete ($BIN_COUNT benchmarks x $ITERATIONS_EXPECTED iterations), skipping."
        continue
    fi

    mkdir -p "$RESULTS_DIR"

    STRESS_PID=""
    if [[ "$config" != "baseline" ]]; then
        stress_type=$(sed -E 's/([a-z]+)[0-9]+/\1/' <<< "$config")
        stress_count=$(sed -E 's/[a-z]+([0-9]+)/\1/' <<< "$config")

        # nice 19: the stressors must saturate the cores, but must never starve
        # the RCU kthreads or the harness. Combined with rcutree.kthread_prio=1
        # this is what keeps CPU hotplug (and so `jailhouse cell create`) alive.
        nice -n 19 stress-ng --"$stress_type" "$stress_count" --timeout "$STRESS_TIMEOUT" \
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
    REQUIRE=()
    [[ -n "$STRESS_PID" ]] && REQUIRE=(--require-pid "$STRESS_PID")

    "$BENCH_SCRIPT" -o "$RESULTS_DIR" "${REQUIRE[@]}" "${BENCH_ARGS[@]}" 2>&1 \
        | tee "${LOG_DIR}/bench_${config}.log"
    BENCH_EXIT=${PIPESTATUS[0]}
    if [[ $BENCH_EXIT -eq 3 ]]; then
        echo "ERROR: the stressor died mid-configuration, so $config is INCOMPLETE." >&2
        echo "       No unstressed data was recorded. Rerun with --resume to finish it." >&2
    elif [[ $BENCH_EXIT -ne 0 ]]; then
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
    full=0
    for f in "$d"/results_*.txt; do
        [[ -e $f ]] || continue
        (( $(wc -l < "$f") == ITERATIONS_EXPECTED )) && full=$((full + 1))
    done
    dropped=""
    [[ -s "$d/DROPPED.txt" ]] && dropped="  DROPPED: $(cut -d' ' -f1 "$d/DROPPED.txt" | paste -sd' ')"
    echo "  ${config}_raw: $full/$BIN_COUNT complete${dropped}"
done
