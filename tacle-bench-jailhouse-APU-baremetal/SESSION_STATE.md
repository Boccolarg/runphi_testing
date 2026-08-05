# Session state — 2026-08-04

Working notes for picking this up cold. The *technical* record lives in
[README.md](README.md) (experiment, deadlocks, dead ends) and
`environment_builder/HANDOFF_zcu104_jailhouse_kernel.md` (kernel rebuild +
TFTP/NFS). This file only holds what those two do not: current state, what is
uncommitted, and what is still open.

## Where the campaign stands

| configuration | state |
|---|---|
| `baseline_raw` | **complete**, 52/52 |
| `fork4_raw` | **complete**, 52/52 |
| `open4_raw` | **complete**, 52/52 |
| `memcpy4_raw` | 17/52 — blocked |
| `cpu4_raw` | 10/52 — blocked |
| `udp4_raw` | 8/52 — blocked |
| `cpu2_raw` | 0/52 — an abandoned experiment, safe to delete |

Data is on the board at `/root/taclebench/results/APU_jailhouse/shmem/`.
Partial data from the blocked three **is valid as far as it goes**: any file with
31 lines was measured under a live stressor, because `--require-pid` aborts
rather than recording unstressed runs. Only `anagram` under `memcpy4` was
dropped (recorded in `memcpy4_raw/DROPPED.txt`).

Quarantined, deliberately not ending in `_raw` so `extract_time.sh` ignores them:
`fork8_raw.INVALID-stressor-timed-out` (46/52 measured with no stressor running)
and `memcpy8_raw.SUPERSEDED-8workers`.

**Blocker:** the board runs a `PREEMPT_NONE` kernel; the KV260 ran `PREEMPT_RT`.
Diagnosis and the five measured dead ends are in [README.md](README.md) under
"The two deadlocks". The fix is a kernel rebuild, handed off, **not yet done**.
The user chose to document rather than rebuild for now.

## Nothing is committed — inventory

### `runphi_testing`

- `tacle-bench-jailhouse-APU-baremetal/README.md` — rewritten this session
- `tacle-bench-jailhouse-APU-baremetal/external_script_shmem.sh` — cell reuse,
  `run_bounded`, `--require-pid`, `--resume`, per-benchmark cap, stressor pausing
- `tacle-bench-jailhouse-APU-baremetal/stressor.sh` — 4 workers, `nice 19`,
  `-c/--configs`, EDAC unbind, cpufreq guard, `chrt` fallback

Not yet committed but self-consistent and deployed to the board at
`/root/taclebench/workdirs/APU_jailhouse/`.

### `environment_builder`

⚠️ **`environment/zcu104/jailhouse/custom_build/jailhouse/configs/arm64/zynqmp-zcu104-APU-inmate-demo.c`
is untracked and exists only on this workstation.** It defines the cell's
system-counter (`0xff250000`) and shared-memory (`0x3ad00000`) regions — without
it the measurement cannot be reproduced. **Commit this first.**

Other untracked items worth keeping: `HANDOFF_zcu104_jailhouse_kernel.md`,
`environment/zcu104/jailhouse/DEMO.md`,
`boot_sources/boot_jailhouse.cmd` (+ the `.isolcpus2-3.bak` and `.pre-rcuprio.bak`
revert points).

Modified: `environment_cfgs/zcu104-jailhouse.sh` (where the `LINUX_CONFIG` fix
goes), `scripts/common/set_environment.sh`, `scripts/compile/jailhouse_compile.sh`,
and several `output/boot/` binaries — check whether those belong in git.

⚠️ There is an untracked **`.bashrc` in the repo root** that almost certainly
should not be committed.

## Board state right now

Idle, nothing running, no screen session. Jailhouse may not be enabled after the
last power cycle. Before any run: `/root/max_perf.sh`, unbind `cortex_edac`, and
`jailhouse_start.sh` — `stressor.sh` handles the EDAC unbind itself.

## Open threads

1. **Kernel rebuild** — handed off. Root cause is `LINUX_CONFIG=""` in
   `environment_cfgs/zcu104-jailhouse.sh`; see the handoff doc.
2. **TFTP/NFS boot** for `zcu104/jailhouse`, modelled on `zcu104/xen`, servers on
   `192.168.100.45`. Same handoff.
3. **Finish the three blocked configurations** once the kernel is rebuilt. Rerun
   with `stressor.sh --resume -c "cpu4 udp4 memcpy4"`; completed configurations
   are skipped automatically.
4. **Reconsider 8 workers** after the rebuild — the KV260 ran 8 fine on
   `PREEMPT_RT`, and going back would restore comparability with the published
   columns. The `_raw` directory names encode the worker count, so a mixed
   campaign would be self-labelling but not directly comparable.
5. **`spiegazione.txt`** is superseded by the README and can be deleted along with
   `DEMO.md` when the user is ready.
6. Restore `isolcpus=domain,managed_irq,2-3` before rerunning the **container
   boot-overhead** benchmarks on this board — they assume cores 2-3 isolated.
