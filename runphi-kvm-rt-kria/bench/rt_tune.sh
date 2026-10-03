#!/bin/sh
#
# rt_tune.sh [--show] - host real-time settings for the campaign, applied after
# every boot (none of them survives a reboot), then checked. The KV260
# equivalents of the students' settings:
#
#   students (x86)                         KV260
#   isolcpus/nohz_full/rcu_nocbs/           kernel command line, from isolargs.txt
#     irqaffinity on the boot cmdline       (/root/boot_mode.sh iso 3): checked here
#   SMT off (nosmt)                         Cortex-A53 has no SMT
#   C-states: max_cstate=1, idle=0          kernel without CPU_IDLE: WFI only
#   P-states/governor performance,          only the userspace governor exists:
#     frequency locked, no turbo            fixed at cpuinfo_max_freq (1.33 GHz)
#   sched_rt_runtime_us = -1                same
#   timer_migration = 0                     same
#
# With --show, only print the current state. Exits 1 if a check fails.

ISO=3
HK=0-2

if [ "$1" != "--show" ]; then
	for p in /sys/devices/system/cpu/cpufreq/policy*; do
		max=$(cat "$p/cpuinfo_max_freq")
		echo userspace >"$p/scaling_governor"
		echo "$max" >"$p/scaling_max_freq"
		echo "$max" >"$p/scaling_min_freq"
		echo "$max" >"$p/scaling_setspeed"
	done
	echo -1 >/proc/sys/kernel/sched_rt_runtime_us
	echo 0 >/proc/sys/kernel/timer_migration
fi

fail=0
check() { # <what> <actual> <expected>
	if [ "$2" = "$3" ]; then
		printf '%-28s %s\n' "$1" "$2"
	else
		printf '%-28s %s   <-- expected %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

echo "kernel:  $(uname -rv)"
echo "cmdline: $(cat /proc/cmdline)"
echo "root:    $(awk '$2 == "/" { print $1, $3 }' /proc/mounts | tail -1)"
echo "runphi:  $(/usr/local/sbin/runphi --version 2>&1 | head -1), md5 $(md5sum /usr/local/sbin/runphi | cut -d' ' -f1)"
check isolated "$(cat /sys/devices/system/cpu/isolated)" "$ISO"
check nohz_full "$(cat /sys/devices/system/cpu/nohz_full)" "$ISO"
grep -q "rcu_nocbs=$ISO" /proc/cmdline && r=yes || r=no
check "rcu_nocbs=$ISO on cmdline" $r yes
check default_smp_affinity "$(cat /proc/irq/default_smp_affinity)" 7
check realtime "$(cat /sys/kernel/realtime 2>/dev/null)" 1
check sched_rt_runtime_us "$(cat /proc/sys/kernel/sched_rt_runtime_us)" -1
check timer_migration "$(cat /proc/sys/kernel/timer_migration)" 0
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	check "$(basename "$p") governor" "$(cat "$p/scaling_governor")" userspace
	check "$(basename "$p") cur_freq" "$(cat "$p/scaling_cur_freq")" "$(cat "$p/cpuinfo_max_freq")"
	echo "$(basename "$p") related_cpus     $(cat "$p/related_cpus")"
done
[ -d /sys/devices/system/cpu/cpuidle ] && r=present || r=absent
check "cpuidle" $r absent
# Movable IRQs that can still fire on the isolated CPU
moved=0
for f in /proc/irq/[0-9]*/smp_affinity_list; do
	a=$(cat "$f")
	case ",$a," in *",$ISO,"* | *"-$ISO,"* | *",$ISO-"* | *"0-3"*)
		moved=$((moved + 1)) ;; esac
done
echo "IRQs whose affinity includes CPU $ISO: $moved"
exit $fail
