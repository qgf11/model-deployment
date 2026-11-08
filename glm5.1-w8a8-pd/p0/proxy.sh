#!/usr/bin/env bash
# Run on the P0 Linux HOST.
set -euo pipefail
NODE_ID=p0
PROCESS_KIND=proxy
CONTAINER_SUFFIX=-proxy
CONTAINER_ENTRY=proxy_container.sh
node_args=()
source "$(dirname -- "${BASH_SOURCE[0]}")/host_common.sh"
host_main "$@"
