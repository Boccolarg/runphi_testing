#!/usr/bin/env bash
# ==============================================================================
# Setup deterministico CPU 6 (Core Isolato Real-Time) - i5-13420H
# ==============================================================================
set -euo pipefail

TARGET_CPU=3
CPU_PATH="/sys/devices/system/cpu/cpu${TARGET_CPU}"
HOUSEKEEPING_CPUS="0-2"

echo "[TUNE] Configurazione low-latency per CPU $TARGET_CPU..."

# 1. Disabilitazione di tutti i C-state profondi (stato 1 in su)
shopt -s nullglob
for state in "$CPU_PATH"/cpuidle/state[1-9]*; do
    if [ -f "$state/disable" ]; then
        echo 1 > "$state/disable"
    fi
done
shopt -u nullglob

# 2. Impostazione governor performance
if [ -f "$CPU_PATH/cpufreq/scaling_governor" ]; then
    echo "performance" > "$CPU_PATH/cpufreq/scaling_governor"
fi

# 3. Disabilitazione Intel Turbo Boost per evitare thermal throttling
if [ -f "/sys/devices/system/cpu/intel_pstate/no_turbo" ]; then
    echo "1" > /sys/devices/system/cpu/intel_pstate/no_turbo
fi

# 4. Fissaggio frequenza statica alla frequenza base
if [ -f "$CPU_PATH/cpufreq/base_frequency" ]; then
    TARGET_FREQ=$(cat "$CPU_PATH/cpufreq/base_frequency")
elif [ -f "$CPU_PATH/cpufreq/cpuinfo_max_freq" ]; then
    TARGET_FREQ=$(cat "$CPU_PATH/cpufreq/cpuinfo_max_freq")
else
    TARGET_FREQ=""
fi

if [ -n "$TARGET_FREQ" ]; then
    echo "$TARGET_FREQ" > "$CPU_PATH/cpufreq/scaling_min_freq"
    echo "$TARGET_FREQ" > "$CPU_PATH/cpufreq/scaling_max_freq"
    echo "[TUNE] Frequenza CPU $TARGET_CPU bloccata a: ${TARGET_FREQ} kHz"
fi

# 5. Disabilitazione RT Throttling (100% tempo CPU a SCHED_FIFO)
if [ -f "/proc/sys/kernel/sched_rt_runtime_us" ]; then
    echo -1 > /proc/sys/kernel/sched_rt_runtime_us
    echo "[TUNE] RT Throttling disabilitato (sched_rt_runtime_us = -1)"
fi

# 6. Disabilitazione migrazione dei timer software
if [ -f "/proc/sys/kernel/timer_migration" ]; then
    echo 0 > /proc/sys/kernel/timer_migration
    echo "[TUNE] Timer migration disabilitata (timer_migration = 0)"
fi

# 7. Reindirizzamento IRQ runtime lontano dalla CPU 6
if [ -f "/proc/irq/default_smp_affinity_list" ]; then
    echo "$HOUSEKEEPING_CPUS" > /proc/irq/default_smp_affinity_list 2>/dev/null || true
fi

shopt -s nullglob
for irq_affinity in /proc/irq/[0-9]*/smp_affinity_list; do
    echo "$HOUSEKEEPING_CPUS" > "$irq_affinity" 2>/dev/null || true
done
shopt -u nullglob
echo "[TUNE] IRQ riallocati sui core di housekeeping ($HOUSEKEEPING_CPUS)"

echo "[TUNE] CPU $TARGET_CPU configurata con successo."
