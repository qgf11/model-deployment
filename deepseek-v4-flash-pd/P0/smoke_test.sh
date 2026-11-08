#!/usr/bin/env bash
# Host entry: use Python/curl from the container and save output under /data1.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
(( $# == 0 )) || { echo 'Usage: bash smoke_test.sh' >&2; exit 2; }
check_settings
check_container_owner
exec docker exec --workdir "$SCRIPT_DIR" "$CONTAINER_NAME" bash ./smoke_in_container.sh
