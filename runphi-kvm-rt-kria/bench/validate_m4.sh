#!/bin/sh
# Quick validation of bench/m4.py: one short iteration (runc + runPHI, 3000
# cyclictest loops) of every M4 campaign and 2 lifecycle iterations per mode,
# results in /root/rtbench/results_m4_quick.
R=/root/rtbench
for c in steady matrixprod callfunc irq memcpy tlb_shootdown stream hdd_sync io_uring socket; do
	python3 $R/bench/rtbench.py campaign m4_$c --quick --runs 1
done
for m in cold warm; do
	python3 $R/bench/rtbench.py campaign m4_life_$m --quick --runs 2
done
echo VALIDATION DONE
