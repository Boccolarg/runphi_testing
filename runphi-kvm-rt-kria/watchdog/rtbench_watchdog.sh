#!/bin/bash
#
# rtbench_watchdog.sh - run on the server (192.168.100.45), as root, in a
# detached screen session, while the KV260 works through the rtbench queue on
# its own (see ../README.md):
#
#   screen -dmS rtbench-watchdog /root/rtbench_watchdog.sh
#   screen -r rtbench-watchdog        # look at it (Ctrl-a d to detach)
#   tail -f /root/rtbench_watchdog.log
#
# Every INTERVAL s it reads the board's progress counter (bumped at every boot
# and after every completed run). If the counter does not move for STALL s,
# the board is assumed hung and is power-cycled through the Tapo outlet
# OUTLET, at most MAX_CYCLES times. When the board reports FINISHED, the
# results are copied to DEST on this server and the watchdog exits; it also
# exits when the board's state/ENABLED disappears (campaign stopped by hand).
# Each check is one ssh login, so it is kept infrequent: it runs on the
# board's housekeeping CPUs, not on the isolated one.

BOARD=${BOARD:-192.168.100.46}
OUTLET=${OUTLET:-kv260}
INTERVAL=${INTERVAL:-300}
STALL=${STALL:-1500}
MAX_CYCLES=${MAX_CYCLES:-6}
LOG=${LOG:-/root/rtbench_watchdog.log}
DEST=${DEST:-/root/rtbench-kv260}
TAPO=/tools/tapo/tapo_control.py

eval "$(grep '^export TAPO_' /root/.bashrc)"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
board() {
	timeout 120 sshpass -p root ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 \
		-o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR root@"$BOARD" "$@"
}
fetch() {
	mkdir -p "$DEST"
	board 'tar -C /root/rtbench -cf - results logs state queue' | tar -C "$DEST" -xf - &&
		log "results copied to $DEST"
}

last=""
last_change=$(date +%s)
cycles=0
log "watching $BOARD: check every ${INTERVAL}s, power-cycle $OUTLET after ${STALL}s without progress"
while :; do
	out=$(board 'cat /root/rtbench/state/progress 2>/dev/null || echo 0; ls /root/rtbench/state; cat /root/rtbench/state/DISABLED_REASON 2>/dev/null')
	if [ -n "$out" ]; then
		prog=$(echo "$out" | head -1)
		if echo "$out" | grep -qx FINISHED; then
			log "board reports FINISHED (progress $prog)"
			fetch
			exit 0
		fi
		if ! echo "$out" | grep -qx ENABLED; then
			log "state/ENABLED is gone ($(echo "$out" | tail -1)): stopping"
			fetch
			exit 0
		fi
		if [ "$prog" != "$last" ]; then
			last=$prog
			last_change=$(date +%s)
			log "progress $prog"
		fi
	else
		log "board not reachable"
	fi
	idle=$(($(date +%s) - last_change))
	if [ $idle -ge "$STALL" ]; then
		if [ $cycles -ge "$MAX_CYCLES" ]; then
			log "no progress for ${idle}s after $cycles power cycles: giving up"
			exit 1
		fi
		cycles=$((cycles + 1))
		log "no progress for ${idle}s: power cycle $cycles/$MAX_CYCLES"
		$TAPO "$OUTLET" off >>"$LOG" 2>&1
		sleep 20
		$TAPO "$OUTLET" on >>"$LOG" 2>&1
		last_change=$(date +%s)
	fi
	sleep "$INTERVAL"
done
