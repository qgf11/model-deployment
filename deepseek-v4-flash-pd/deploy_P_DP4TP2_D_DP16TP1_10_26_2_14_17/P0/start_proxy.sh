#!/usr/bin/env bash
# Host entry, run only after all engine endpoints are healthy.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cmd=(docker exec --workdir "$SCRIPT_DIR" "$CONTAINER_NAME" bash ./service_control.sh start proxy)
if [[ ${1:-} == --dry-run && $# == 1 ]]; then print_command "${cmd[@]}"; exit 0; fi
(( $# == 0 )) || { echo 'Usage: bash start_proxy.sh [--dry-run]' >&2; exit 2; }
check_settings
check_container_owner
exec "${cmd[@]}"
