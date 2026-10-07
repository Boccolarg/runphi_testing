# Kernel patches of the TLB experiment

The record of how the KVM fix was found. These patches are **not** meant to be
applied: the fix that the kria-kvm environment applies is
`environment_builder/environment/kria/kvm/custom_build/linux/patch/kvm_stage2_free_flush/`
(TLBI ALLE1IS when a VM that has run is torn down). See the README one level
up, "The cause: the dead guest's TLB entries".

| Patch | What it does | Result |
|---|---|---|
| `0000-first-attempt-...` | invalidates the dead VM's VMID (`__kvm_tlb_flush_vmid`, TLBI VMALLS12E1IS) in `kvm_free_stage2_pgd()` | does not help |
| `0001-EXPERIMENT-...` | on top of 0000: `/sys/module/kvm/parameters/stage2_free_flush` picks the invalidation at run time (0 none, 1 the VM's VMID, 2 all VMIDs, 3 the host's stage 1), `stage2_free_flushes` counts them | only 2 helps |
| `0002-EXPERIMENT-...` | on top of 0001: modes 4 (VMID 0, stage 1 and 2), 5 (1 + 4), 6 (1 + 3); boot parameter `a53_specat` turns on `ARM64_WORKAROUND_SPECULATIVE_AT` for the Cortex-A53 | none of 4-6 helps; the workaround does not help, with mode 0 or 1 |

They apply to the board's kernel tree (linux-xlnx 6.1.70 with the preempt_rt
patch) in this order, for example with
`scripts/patch/linux_patch.sh -t kria -b kvm -d <dir>` from a patch directory
of the environment. `bench/order_probe.py` has the matching probe variants
(`flush0`-`flush6`, `flush2_runphi`, `specat`, `specat1`).
