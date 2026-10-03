#!/bin/sh
# Quick validation of the harness: 1 short run of every FFI campaign and 2
# lifecycle runs of each mode, results in /root/rtbench/results_quick.
R=/root/rtbench
for p in baseline matrixprod callfunc irq memcpy stream tlb_shootdown hdd_sync io_uring socket; do
	for rt in runc kvm; do
		python3 $R/bench/rtbench.py campaign ffi_${rt}_$p --quick --runs 1
	done
done
for rt in runc kvm; do
	for m in cold warm; do
		python3 $R/bench/rtbench.py campaign life_${rt}_$m --quick --runs 2
	done
done
echo VALIDATION DONE
