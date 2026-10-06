#!/bin/sh
#
# build_guest_image.sh <tag> [warmup_s] [loops] [init] [repository] - build
# the runPHI-KVM image <repository>:<tag> (default rtbench-kvm:<tag>) on the
# board. [init] is the guest's benchmark init script, S99rtbench by default;
# S99m4 for the students' own procedure (bench/m4.py), e.g.
#   build_guest_image.sh runphi 0 30000 S99m4 rt-cyclictest
#
# Guest: the kria-kvm kernel (a copy of the host's PREEMPT_RT Image, in
# /root/guest) and the Buildroot initramfs already used by the runPHI test
# images, with
# - the init script added as /etc/init.d/S99rtbench (see that file),
#   WARMUP/LOOPS substituted;
# - the network services removed (S40network, S41dhcpcd, S50dropbear): the
#   guest has no network device ("net": "no"), so they would only wait.
# /boot/config.json is the students' one (runPHI-presentation.pdf, "runPHI
# container config"): 1 vCPU pinned to the isolated CPU 3, 1024 MB, no
# network, host IRQs steered to CPUs 0-2.
set -e
umask 022

TAG=${1:?usage: $0 <tag> [warmup_s] [loops] [init] [repository]}
WARMUP=${2:-30}
LOOPS=${3:-30000}
INIT=${4:-S99rtbench}
REPO=${5:-rtbench-kvm}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=/tmp/rtbench-kvm-$TAG

rm -rf "$WORK"
mkdir -p "$WORK/rootfs" "$WORK/image/boot"
cd "$WORK/rootfs"
zcat /root/guest/rootfs.cpio.gz | cpio -id 2>/dev/null
rm -f etc/init.d/S40network etc/init.d/S41dhcpcd etc/init.d/S50dropbear
sed -e "s/@WARMUP@/$WARMUP/" -e "s/@LOOPS@/$LOOPS/" "$HERE/$INIT" >etc/init.d/S99rtbench
chmod 755 etc/init.d/S99rtbench
python3 "$HERE/mkcpio.py" . | gzip -9 >"$WORK/image/boot/rootfs.cpio.gz"

cp /root/guest/Image "$WORK/image/boot/Image"
cat >"$WORK/image/boot/config.json" <<JSON
{
    "os_var": "linux",
    "inmate": "/boot/Image",
    "ramdisk": "/boot/rootfs.cpio.gz",
    "memory": 1024,
    "net": "no",
    "vcpus": 1,
    "vcpu_pinning": [
        { "vcpu": 0, "pcpu": 3 }
    ],
    "steer_irq": [0,1,2]
}
JSON

cd "$WORK/image"
docker rmi "$REPO:$TAG" >/dev/null 2>&1 || true
tar -c . | docker import --change 'CMD ["/bin/sh"]' - "$REPO:$TAG"
rm -rf "$WORK"
echo "built $REPO:$TAG ($INIT, warm-up ${WARMUP}s, $LOOPS loops)"
