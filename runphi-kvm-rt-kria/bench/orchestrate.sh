#!/bin/sh
#
# orchestrate.sh - run the next campaign of the queue, then reboot.
#
# Started at every boot by /etc/init.d/S99rtbench while state/ENABLED exists,
# so the board works through the queue unattended, rebooting between
# campaigns as the students did. Files in /root/rtbench:
#   queue                 one campaign name per line (see bench/rtbench.py)
#   state/done            campaigns completed
#   state/failed          campaigns given up (2 failed attempts)
#   state/attempts.<name> attempts so far (an attempt that ends with exit 3,
#                         "reboot needed", is not counted: see state/reboots.<name>)
#   state/progress        counter bumped at every boot and every completed run,
#                         watched from the server by rtbench_watchdog.sh
#   state/FINISHED        written when the queue is empty
#   logs/orchestrate.log  this script's log, logs/<campaign>.log each campaign's
# To stop after the current campaign: rm /root/rtbench/state/ENABLED

R=/root/rtbench
S=$R/state
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
mkdir -p $S $R/logs
exec >>$R/logs/orchestrate.log 2>&1

[ -f $S/ENABLED ] || exit 0

ts() { echo "[$(cut -d' ' -f1 /proc/uptime)] $*"; }
bump() { n=$(cat $S/progress 2>/dev/null || echo 0); echo $((n + 1)) >$S/progress.new && mv $S/progress.new $S/progress; }
disable() { ts "DISABLED: $*"; echo "$*" >$S/DISABLED_REASON; rm -f $S/ENABLED; sync; exit 1; }

boots=$(($(cat $S/boots 2>/dev/null || echo 0) + 1))
echo $boots >$S/boots
bump
ts "=== boot $boots ($(cat /proc/sys/kernel/random/boot_id))"
[ $boots -le ${MAX_BOOTS:-80} ] || disable "more than ${MAX_BOOTS:-80} boots"

# Wait for Docker and libvirt, then let the boot settle
i=0
until docker info >/dev/null 2>&1 && virsh list >/dev/null 2>&1; do
	i=$((i + 1))
	[ $i -le 60 ] || disable "docker/libvirtd not up after 120 s"
	sleep 2
done
sleep 30

$R/bench/rt_tune.sh >$R/logs/rt_tune.last 2>&1 || {
	cat $R/logs/rt_tune.last
	disable "rt_tune.sh checks failed"
}

next=""
while read -r c; do
	case "$c" in "" | \#*) continue ;; esac
	grep -qx "$c" $S/done 2>/dev/null && continue
	grep -qx "$c" $S/failed 2>/dev/null && continue
	next=$c
	break
done <$R/queue

if [ -z "$next" ]; then
	ts "queue empty: FINISHED"
	touch $S/FINISHED
	rm -f $S/ENABLED
	sync
	exit 0
fi

a=$(($(cat $S/attempts.$next 2>/dev/null || echo 0) + 1))
echo $a >$S/attempts.$next
ts "campaign $next (attempt $a)"
python3 $R/bench/rtbench.py campaign "$next" >>$R/logs/$next.log 2>&1
rc=$?
ts "campaign $next exited $rc"
if [ $rc -eq 0 ]; then
	echo "$next" >>$S/done
elif [ $rc -eq 3 ]; then
	# libvirtd stopped (or a container could not be removed): the campaign
	# resumes after the reboot; give up only if this keeps happening
	echo $((a - 1)) >$S/attempts.$next
	r=$(($(cat $S/reboots.$next 2>/dev/null || echo 0) + 1))
	echo $r >$S/reboots.$next
	ts "campaign $next needs a reboot ($r)"
	[ $r -lt 10 ] || echo "$next" >>$S/failed
elif [ $a -ge 2 ]; then
	echo "$next" >>$S/failed
fi

[ -f $S/ENABLED ] || { ts "ENABLED removed: not rebooting"; exit 0; }
sync
sleep 5
ts "rebooting"
reboot
