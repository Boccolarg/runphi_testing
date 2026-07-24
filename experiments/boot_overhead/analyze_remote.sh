#!/bin/bash
#*********************************************
# runPHI boot-overhead experiment: pull-and-analyze helper.
#
# Runs on your workstation (not the board). Copies a results directory off
# the board via scp, then analyzes it locally with analyze.py. Use this when
# the board's userland is too minimal to run the analysis (e.g. BusyBox awk
# without math support).
#
# Usage:
#   ./analyze_remote.sh [user@]host REMOTE_RESULTS_DIR [local_dest] [-- analyze.py args]
#
# Examples:
#   ./analyze_remote.sh root@192.168.100.47 /root/boot_overhead/results/20260527-212050
#   ./analyze_remote.sh root@192.168.100.47 /root/boot_overhead/results/run ./pulled -- --warmup 2 --csv
#
# Auth: if SSHPASS is set in the environment and sshpass is installed, it is
# used; otherwise scp/ssh prompt normally (key or password).
#
# Transfer uses scp -O (legacy protocol) because minimal boards often lack
# an sftp-server, which modern scp requires by default.
#*********************************************

set -euo pipefail

if [[ $# -lt 2 ]]; then
    sed -n '2,20p' "$0"
    exit 1
fi

HOST="$1"; shift
REMOTE_DIR="$1"; shift

LOCAL_DEST="./results/pulled-$(date +%Y%m%d-%H%M%S)"
if [[ $# -gt 0 && "$1" != "--" ]]; then
    LOCAL_DEST="$1"; shift
fi
[[ "${1:-}" == "--" ]] && shift
ANALYZE_ARGS=("$@")

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

scp_cmd=(scp -O)
if [[ -n "${SSHPASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    scp_cmd=(sshpass -e scp -O)
fi

mkdir -p "$LOCAL_DEST"
echo "Pulling $HOST:$REMOTE_DIR -> $LOCAL_DEST"
# Recursively copy the remote dir; scp -O creates a subdir named after it.
# shellcheck disable=SC2086
"${scp_cmd[@]}" $SSHOPTS -r "$HOST:$REMOTE_DIR" "$LOCAL_DEST/"

# Point the analyzer at the directory that actually holds the *_launch.txt
# files (either LOCAL_DEST itself or the single subdir scp just created).
target="$LOCAL_DEST"
if ! ls "$LOCAL_DEST"/*_launch.txt >/dev/null 2>&1; then
    sub=$(ls -d "$LOCAL_DEST"/*/ 2>/dev/null | head -1)
    [[ -n "$sub" ]] && target="$sub"
fi

echo
python3 "$SCRIPT_DIR/analyze.py" --dir "$target" "${ANALYZE_ARGS[@]}"
