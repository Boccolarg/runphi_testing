#!/bin/sh
# Container entrypoint: the same sequence as the KVM guest's S99rtbench.
#   RTBENCH READY  -> the harness starts the stressors on the host
#   WARMUP seconds -> stressors reach steady state
#   cyclictest     -> LOOPS x 1 ms on the isolated CPU (CPU, default 3)
# docker stop sends SIGTERM to PID 1 (this shell), which ignores it by
# default: trap it so that stopping during the warm-up is immediate. The final
# exec makes cyclictest PID 1, and cyclictest exits on SIGTERM itself.
trap 'exit 143' TERM INT
echo "RTBENCH READY"
sleep "${WARMUP:-30}" &
wait $!
exec cyclictest -p 99 -i 1000 -l "${LOOPS:-30000}" -m -a "${CPU:-3}" -q
