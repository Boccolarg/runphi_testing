#!/bin/sh
#
# boot_bench.sh - boot-time benchmark for real-time containers.
#
#   -r N        number of repetitions          (default 200)
#   -c on|off   drop caches between iterations (default on)
#   -i IMAGE    container image                (default alpine)
#   -u SEC      seconds to leave container up  (default 2)
#   -g SEC      gap between iterations         (default 3)
#   -p CPUS     cpuset to pin to, e.g. 2,3     (default none)
#   -w N        warm-up iterations to discard  (default 1, 0 = none)
#   -n NETWORK  docker --network value         (default none; e.g. bridge)
#   -s on|off   also timestamp OCI start       (default off)
#
set -u

ITERATIONS=200
FLUSH_CACHE=1
IMAGE=alpine
CMD=/home/booted
UP_TIME=2
GAP=3
CPUSET=""
WARMUP=1
NETWORK=none
MEASURE_START=0
START_MARKER=/run/rt_measure_start
VOLUME=/root/container_volume
TIMES=$VOLUME/times.txt

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
}

while getopts "r:c:i:u:g:p:w:n:s:h" opt; do
    case "$opt" in
        r) ITERATIONS=$OPTARG ;;
        c) case "$OPTARG" in
               on|ON|yes|1|true)   FLUSH_CACHE=1 ;;
               off|OFF|no|0|false) FLUSH_CACHE=0 ;;
               *) echo "invalid -c value: $OPTARG (use on|off)" >&2; exit 2 ;;
           esac ;;
        i) IMAGE=$OPTARG ;;
        u) UP_TIME=$OPTARG ;;
        g) GAP=$OPTARG ;;
        p) CPUSET=$OPTARG ;;
        w) WARMUP=$OPTARG ;;
        n) NETWORK=$OPTARG ;;
        s) case "$OPTARG" in
               on|ON|yes|1|true)   MEASURE_START=1 ;;
               off|OFF|no|0|false) MEASURE_START=0 ;;
               *) echo "invalid -s value: $OPTARG (use on|off)" >&2; exit 2 ;;
           esac ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

case "$ITERATIONS" in
    ''|*[!0-9]*) echo "-r must be a positive integer" >&2; exit 2 ;;
esac
[ "$ITERATIONS" -gt 0 ] || { echo "-r must be > 0" >&2; exit 2; }

case "$WARMUP" in
    ''|*[!0-9]*) echo "-w must be a non-negative integer" >&2; exit 2 ;;
esac

[ -n "$NETWORK" ] || { echo "-n must name a docker network (e.g. none, bridge, host)" >&2; exit 2; }

if [ "$FLUSH_CACHE" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "cache flushing needs root; run as root or pass -c off" >&2
    exit 1
fi

# Gate the shim's optional OCI-"start" timestamp via a marker file it checks on
# each start (path must match START_MARKER in rt_shim.c). Managed here so START
# measurement is active only for this run; the trap clears it even on Ctrl-C.
trap 'rm -f "$START_MARKER"' EXIT INT TERM
if [ "$MEASURE_START" -eq 1 ]; then
    touch "$START_MARKER" || { echo "cannot create $START_MARKER" >&2; exit 1; }
else
    rm -f "$START_MARKER"
fi

# No option below contains whitespace, so unquoted expansion is safe here.
DOCKER_OPTS="--rm -d
             --network $NETWORK
             --cpu-rt-runtime=950000
             --cpu-rt-period=1000000
             -v $VOLUME:/home
             --privileged"

[ -n "$CPUSET" ] && DOCKER_OPTS="$DOCKER_OPTS --cpuset-cpus=$CPUSET"

# One container: start it, leave it up, tear it down, optionally drop caches,
# then wait the inter-iteration gap. $1 = container name, $2 = log label.
run_one() {
    _name=$1
    _label=$2
    echo "$_label ($_name)..."
    if ! docker run $DOCKER_OPTS --name "$_name" "$IMAGE" "$CMD" >/dev/null; then
        echo "  $_label: docker run failed, skipping" >&2
        sleep "$GAP"
        return 1
    fi
    sleep "$UP_TIME"
    docker stop  "$_name" >/dev/null 2>&1
    docker rm -f "$_name" >/dev/null 2>&1
    if [ "$FLUSH_CACHE" -eq 1 ]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches
        sleep 1
    fi
    sleep "$GAP"
}

echo "iterations=$ITERATIONS warmup=$WARMUP flush_cache=$FLUSH_CACHE network=$NETWORK start_measure=$MEASURE_START image=$IMAGE cpuset=${CPUSET:-none}"

# Warm-up (discarded): the first container of a run is consistently an outlier,
# so run $WARMUP throwaway iteration(s) before we start recording.
w=1
while [ "$w" -le "$WARMUP" ]; do
    run_one "rtwarm_$w" "Warm-up $w/$WARMUP (discarded)"
    w=$((w + 1))
done

# Start the measured run from an empty log. This drops the warm-up record(s) and
# any stale data; both rt_shim and booted O_APPEND here via the bind mount, so a
# leftover file would otherwise be counted as extra repetitions.
: > "$TIMES" || { echo "cannot truncate $TIMES" >&2; exit 1; }

i=1
while [ "$i" -le "$ITERATIONS" ]; do
    run_one "rtboot_$i" "Starting container $i/$ITERATIONS"
    i=$((i + 1))
done

echo "Completed $ITERATIONS iterations ($WARMUP warm-up discarded)."
