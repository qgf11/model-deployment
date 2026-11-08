#!/usr/bin/env bash
# Host entry: create/reuse container, then launch inference in the background.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
dry_run=0
if [[ ${1:-} == --dry-run ]]; then dry_run=1; shift; fi
(( $# == 0 )) || { echo 'Usage: bash start.sh [--dry-run]' >&2; exit 2; }
cmd=(docker exec --workdir "$SCRIPT_DIR" "$CONTAINER_NAME" bash ./service_control.sh start engine)
if (( dry_run )); then
    bash "$SCRIPT_DIR/docker_run.sh" --dry-run
    print_command "${cmd[@]}"
    exit 0
fi
check_settings
bash "$SCRIPT_DIR/docker_run.sh"
exec "${cmd[@]}"
