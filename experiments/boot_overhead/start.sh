#!/bin/bash
#*********************************************
# runPHI boot-overhead experiment: in-container probe.
#
# Runs as the container's init. Captures the kernel-monotonic timestamp
# at the moment this init executes, tagged with the per-iteration RUN_ID
# the host driver passes in. The host records its own timestamp from the
# same clock (/proc/timer_list "now") right before `docker run`, so:
#
#     boot_time = container_now - host_now
#
# Both reads come from the host kernel's monotonic clock (containers
# share the host kernel), so the two values are directly comparable.
#*********************************************

set -u

HOST_TIMER=/host_timer_list   # bind-mount of the host's /proc/timer_list
OUT=/home/times.txt           # shared volume, read back on the host

# Pure-bash read of the first "now at <ns> nsecs" line. We avoid awk/sed
# so the measurement does not depend on coreutils being page-cache-warm
# after a drop_caches in the cold-cache arm.
now_ns=""
while read -r key _at val _unit; do
    if [[ $key == now ]]; then
        now_ns=$val
        break
    fi
done < "$HOST_TIMER"

echo "BOOTED ${RUN_ID:-0} ${now_ns}" >> "$OUT"
