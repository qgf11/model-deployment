#!/usr/bin/env bash
# Run on this machine's Linux HOST, not inside a container.
set -euo pipefail
NODE_ID=d3
PROCESS_KIND=service
CONTAINER_ENTRY=container_entry.sh
node_args=(--dp-size 8 --tp-size 4 --dp-size-local 2 --dp-rank-start 6 --dp-address 192.0.2.20 --dp-rpc-port 10521 --vllm-start-port 6606)
source "$(dirname -- "${BASH_SOURCE[0]}")/host_common.sh"
host_main "$@"
