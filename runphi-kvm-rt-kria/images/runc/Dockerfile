# Minimal Alpine image with rt-tests only (cyclictest), for the runc side of
# the runPHI-KVM vs runc cyclictest campaign.
#
# cyclictest is rt-tests 2.5 ("cyclictest V 2.50"), the same release as on the
# host and in the KVM guest, linked statically against glibc in a Debian build
# stage. Alpine has no rt-tests package, and a musl build does not work here:
# - musl's sched_getscheduler()/sched_setscheduler() return ENOSYS by design,
#   so cyclictest stops with "unable to get scheduler parameters";
# - libnuma (always linked by rt-tests 2.x) sizes its CPU masks with
#   sysconf(_SC_NPROCESSORS_CONF), which musl computes from the affinity mask:
#   inside --cpuset-cpus 3 that is 1 CPU, and "-a 3" fails with "cpu argument
#   3 is out of range" (this arm64 kernel has no NUMA sysfs to fall back on).
# glibc reads /sys/devices/system/cpu instead and has working sched_*() calls.
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libnuma-dev \
 && rm -rf /var/lib/apt/lists/*
ADD https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git/snapshot/rt-tests-2.5.tar.gz /src/
RUN cd /src && tar xzf rt-tests-2.5.tar.gz && cd rt-tests-2.5 \
 && make cyclictest LDFLAGS=-static && strip cyclictest && cp cyclictest /usr/local/bin/

FROM alpine:3.24
COPY --from=build /usr/local/bin/cyclictest /usr/local/bin/cyclictest
COPY rtbench.sh /rtbench.sh
ENTRYPOINT ["/rtbench.sh"]
