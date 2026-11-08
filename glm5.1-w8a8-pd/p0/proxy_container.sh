#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
exec >> "${RUN_LOG:?RUN_LOG is required}" 2>&1
printf "[%s] Starting P0 proxy\n" "$(date -Is)"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

exec python load_balance_proxy_server_example.py \
    --port 9000 \
    --host 192.0.2.10 \
    --prefiller-hosts \
       192.0.2.10 \
       192.0.2.11 \
       192.0.2.12 \
       192.0.2.13 \
    --prefiller-ports \
       6606 \
       6606 \
       6606 \
       6606 \
    --decoder-hosts \
       192.0.2.20 \
       192.0.2.20 \
       192.0.2.21 \
       192.0.2.21 \
       192.0.2.22 \
       192.0.2.22 \
       192.0.2.23 \
       192.0.2.23 \
    --decoder-ports \
       6606 6607 \
       6606 6607 \
       6606 6607 \
       6606 6607
