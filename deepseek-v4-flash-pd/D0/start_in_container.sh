#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
dry_run=0
if [[ ${1:-} == --dry-run ]]; then dry_run=1; shift; fi
(( $# == 0 )) || { echo 'Usage: bash start.sh [--dry-run]' >&2; exit 2; }
if (( ! dry_run )); then
    check_settings
    [[ -f "$MODEL_PATH/config.json" ]] || { echo "Missing $MODEL_PATH/config.json" >&2; exit 1; }
    command -v vllm >/dev/null || { echo 'Run this script inside the configured A2 container.' >&2; exit 1; }
    "$PYTHON_BIN" - "$NIC_NAME" "$LOCAL_IP" <<'IP_CHECK' || exit 1
import fcntl
import socket
import struct
import sys

interface, expected = sys.argv[1:]
try:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        request = struct.pack("256s", interface.encode()[:15])
        result = fcntl.ioctl(sock.fileno(), 0x8915, request)
        actual = socket.inet_ntoa(result[20:24])
except OSError as exc:
    print(f"Cannot read IPv4 address for {interface}: {exc}", file=sys.stderr)
    sys.exit(1)

if actual != expected:
    print(f"{interface} primary IPv4 is {actual}, expected {expected}", file=sys.stderr)
    sys.exit(1)
print(f"Network check passed: {interface} = {actual}")
IP_CHECK
    for device in {0..7}; do
        [[ -e /dev/davinci$device ]] || { echo "Missing /dev/davinci$device" >&2; exit 1; }
    done
    echo "Starting $NODE_NAME: local DP=$DP_SIZE_LOCAL, TP=$TP_SIZE, global DP=$DP_SIZE, address=$DP_ADDRESS"
fi
args=("$SCRIPT_DIR/launch_online_dp.py" --dp-size "$DP_SIZE" --tp-size "$TP_SIZE"
      --dp-size-local "$DP_SIZE_LOCAL" --dp-rank-start "$DP_RANK_START"
      --dp-address "$DP_ADDRESS" --dp-rpc-port "$DP_RPC_PORT" --vllm-start-port "$VLLM_START_PORT")
(( ! dry_run )) || args+=(--dry-run)
exec "$PYTHON_BIN" "${args[@]}"
