#!/bin/sh
#
# emulatorpin_check.sh - check runPHI's emulator pinning on the KV260: where
# QEMU's threads run, the container cpuset, that the guests end by themselves
# and that nothing is left behind. Runs the RUNPHI.md tests 5.1, 5.2, 5.4,
# 5.5 and the benchmark guest (--cpuset-cpus 3).

dom() { echo runphi-$(docker inspect -f '{{.Id}}' "$1" | cut -c1-24); }
qpid() { pidof qemu-system-aarch64; }
show() {
	echo "-- domain.xml cputune:"
	sed -n '/<cputune>/,/<\/cputune>/p' /run/runPHI/*/domain.xml
	echo "-- virsh emulatorpin: $(virsh emulatorpin "$(dom "$1")" | awk '/:/ {print $2}')"
	ps -T -p "$(qpid)" -o tid,comm,psr,cls,rtprio
	for t in /proc/$(qpid)/task/*; do
		printf '%-18s %s\n' "$(cat $t/comm)" "$(grep Cpus_allowed_list $t/status | cut -f2)"
	done
	echo "-- container cpuset: $(cat /sys/fs/cgroup/cpuset/docker/$(docker inspect -f '{{.Id}}' "$1")/cpuset.cpus)"
}
clean() {
	echo "-- left behind: containers [$(docker ps -aq)] domains [$(virsh list --all --name | tr -d '\n')] state [$(ls /run/runPHI)]"
}

echo "===== 5.1 initramfs (no pinning)"
docker run -d --name g1 --runtime=runphi runphi-kvm-guest:initramfs >/dev/null
sleep 4
grep -c emulatorpin /run/runPHI/*/domain.xml
ps -T -p "$(qpid)" -o tid,comm,psr,cls,rtprio
docker rm -f g1 >/dev/null; clean

echo "===== 5.2 pinned-net, --cpuset-cpus 2,3"
docker run -d --name g2 --runtime=runphi --cpuset-cpus 2,3 runphi-kvm-guest:pinned-net >/dev/null
sleep 4; show g2
docker rm -f g2 >/dev/null; clean

echo "===== 5.4 steer (vCPU 0 on 3, no --cpuset-cpus)"
grep -H . /proc/irq/*/smp_affinity_list >/tmp/irq.before
docker run -d --name g4 --runtime=runphi runphi-kvm-guest:steer >/dev/null
sleep 4; sed -n '/<cputune>/,/<\/cputune>/p' /run/runPHI/*/domain.xml
docker rm -f g4 >/dev/null
grep -H . /proc/irq/*/smp_affinity_list | diff /tmp/irq.before - >/dev/null && echo "IRQs restored"
clean

echo "===== 5.5 pinned CPUs outside --cpuset-cpus 0,1"
docker run -d --name bad --runtime=runphi --cpuset-cpus 0,1 runphi-kvm-guest:pinned-net 2>&1 | tail -1
docker rm bad >/dev/null; clean

echo "===== benchmark guest, --cpuset-cpus 3, until it powers off"
docker run -d --name g6 --runtime=runphi --cpuset-cpus 3 -m 1024m --network none \
	--cap-add SYS_NICE --ulimit rtprio=99 --ulimit memlock=-1 rtbench-kvm:quick >/dev/null
sleep 4; show g6
t=0
while [ "$(docker inspect -f '{{.State.Status}}' g6)" = running ] && [ $t -lt 120 ]; do sleep 1; t=$((t + 1)); done
echo "-- status after ${t}s: $(docker inspect -f '{{.State.Status}}' g6)"
grep -E "T: 0|Power down" /var/log/libvirt/qemu/$(dom g6)-serial.log
docker rm g6 >/dev/null; clean
