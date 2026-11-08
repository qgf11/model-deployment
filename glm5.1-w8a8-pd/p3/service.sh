#!/usr/bin/env bash
# Run on this machine's Linux HOST, not inside a container.
set -euo pipefail
NODE_ID=p3
PROCESS_KIND=service
CONTAINER_ENTRY=container_entry.sh
node_args=(--dp-size 4 --tp-size 8 --dp-size-local 1 --dp-rank-start 3 --dp-address 192.0.2.10 --dp-rpc-port 10521 --vllm-start-port 6606)
source "$(dirname -- "${BASH_SOURCE[0]}")/host_common.sh"
host_main "$@"
