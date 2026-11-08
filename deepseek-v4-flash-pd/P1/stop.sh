#!/usr/bin/env bash
# Host entry: stop this node's services and container, retaining files and logs.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
(( $# == 0 )) || { echo 'Usage: bash stop.sh' >&2; exit 2; }
check_container_owner
if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME") != true ]]; then
    echo "Container $CONTAINER_NAME is already stopped."
    exit 0
fi
if [[ "$NODE_NAME" == P0 ]]; then
    docker exec --workdir "$SCRIPT_DIR" "$CONTAINER_NAME" bash ./service_control.sh stop proxy
fi
docker exec --workdir "$SCRIPT_DIR" "$CONTAINER_NAME" bash ./service_control.sh stop engine
docker stop --time 30 "$CONTAINER_NAME"
