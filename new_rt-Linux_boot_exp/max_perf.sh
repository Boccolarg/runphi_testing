#!/bin/sh
# max_perf.sh - lock all CPUs at their maximum frequency and disable deep CPU
# idle states. These settings reset on every boot, so run this once after each
# reboot (e.g. before a benchmark) to keep measurements consistent.
#
# This board's kernel ships only the "userspace" cpufreq governor (no
# "performance"), so we can't just select performance. Instead we pin the
# frequency at the hardware max by setting scaling_min_freq = scaling_max_freq
# (and scaling_setspeed for the userspace governor). If a future kernel adds the
# performance governor, this script prefers it automatically.
set -u

echo "== before =="
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -d "$c" ] || continue
    n=$(basename "$(dirname "$c")")
    printf "  %s gov=%s cur=%s min=%s max=%s\n" "$n" \
        "$(cat "$c/scaling_governor" 2>/dev/null)" \
        "$(cat "$c/scaling_cur_freq" 2>/dev/null)" \
        "$(cat "$c/scaling_min_freq" 2>/dev/null)" \
        "$(cat "$c/scaling_max_freq" 2>/dev/null)"
done

# Make sure every CPU is online first (offline CPUs have no cpufreq dir).
for o in /sys/devices/system/cpu/cpu[0-9]*/online; do
    [ -f "$o" ] && echo 1 > "$o" 2>/dev/null
done

for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -d "$c" ] || continue
    hwmax=$(cat "$c/cpuinfo_max_freq" 2>/dev/null) || continue

    # Prefer the performance governor if this kernel has it; else userspace.
    if grep -qw performance "$c/scaling_available_governors" 2>/dev/null; then
        echo performance > "$c/scaling_governor" 2>/dev/null
    elif grep -qw userspace "$c/scaling_available_governors" 2>/dev/null; then
        echo userspace > "$c/scaling_governor" 2>/dev/null
    fi

    # Raise the ceiling to hwmax, then the floor to the ceiling => locked at max.
    echo "$hwmax" > "$c/scaling_max_freq" 2>/dev/null
    echo "$hwmax" > "$c/scaling_min_freq" 2>/dev/null
    # userspace governor: explicitly request the max frequency.
    [ -w "$c/scaling_setspeed" ] && echo "$hwmax" > "$c/scaling_setspeed" 2>/dev/null
done

echo "== after =="
allmax=1
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -d "$c" ] || continue
    n=$(basename "$(dirname "$c")")
    gov=$(cat "$c/scaling_governor" 2>/dev/null)
    cur=$(cat "$c/scaling_cur_freq" 2>/dev/null)
    mn=$(cat "$c/scaling_min_freq" 2>/dev/null)
    mx=$(cat "$c/scaling_max_freq" 2>/dev/null)
    hw=$(cat "$c/cpuinfo_max_freq" 2>/dev/null)
    printf "  %s gov=%s cur=%s min=%s max=%s (hwmax=%s)\n" "$n" "$gov" "$cur" "$mn" "$mx" "$hw"
    [ "$cur" = "$hw" ] && [ "$mn" = "$hw" ] || allmax=0
done

if [ "$allmax" -eq 1 ]; then
    echo "OK: all CPUs locked at hardware max frequency."
else
    echo "WARN: not all CPUs are at hardware max (see above)." >&2
fi

# Disable deep cpuidle states to cut wake-up latency jitter: keep only the
# shallowest state (state0, WFI) enabled and disable the rest (states are
# registered in order of increasing exit latency). On a kernel without
# CONFIG_CPU_IDLE there are no cpuidle states at all - the CPU already only does
# architectural WFI on idle - so this is a no-op and just reports that.
echo "== cpuidle =="
if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
    for st in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[0-9]*; do
        [ -d "$st" ] || continue
        idx=$(basename "$st"); idx=${idx#state}
        if [ "$idx" -eq 0 ]; then
            [ -w "$st/disable" ] && echo 0 > "$st/disable" 2>/dev/null   # keep WFI
        else
            [ -w "$st/disable" ] && echo 1 > "$st/disable" 2>/dev/null   # disable deep
        fi
    done
    for st in /sys/devices/system/cpu/cpu0/cpuidle/state[0-9]*; do
        [ -d "$st" ] || continue
        printf "  cpu0/%s %s latency=%sus disable=%s\n" "$(basename "$st")" \
            "$(cat "$st/name" 2>/dev/null)" "$(cat "$st/latency" 2>/dev/null)" \
            "$(cat "$st/disable" 2>/dev/null)"
    done
    echo "  deep states disabled on all CPUs; WFI (state0) kept."
else
    echo "  no cpuidle framework (CONFIG_CPU_IDLE off) - CPU already WFI-only idle; nothing to disable."
fi
