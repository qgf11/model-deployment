#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
dry_run=0
if [[ ${1:-} == --dry-run ]]; then dry_run=1; shift; fi
(( $# == 0 )) || { echo 'Usage: bash start_proxy.sh [--dry-run]' >&2; exit 2; }
(( dry_run )) || check_settings
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
export NO_PROXY='*' no_proxy='*'
p_hosts=() p_ports=() d_hosts=() d_ports=()
for host in "$P0_IP" "$P1_IP"; do
    for ((i=0; i<P_DP_SIZE; i++)); do p_hosts+=("$host"); p_ports+=("$((VLLM_START_PORT+i))"); done
done
for host in "$D0_IP" "$D1_IP"; do
    for ((i=0; i<8; i++)); do d_hosts+=("$host"); d_ports+=("$((VLLM_START_PORT+i))"); done
done
cmd=("$PYTHON_BIN" "$SCRIPT_DIR/load_balance_proxy_server_example.py"
     --host "$PROXY_HOST" --port "$PROXY_PORT"
     --prefiller-hosts "${p_hosts[@]}" --prefiller-ports "${p_ports[@]}"
     --decoder-hosts "${d_hosts[@]}" --decoder-ports "${d_ports[@]}")
if (( dry_run )); then print_command "${cmd[@]}"; exit 0; fi
exec "${cmd[@]}"
