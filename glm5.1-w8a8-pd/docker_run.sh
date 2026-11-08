#!/usr/bin/env bash
# Optional convenience entry if the whole project is uploaded to one host.
set -euo pipefail
node="${1:?Usage: bash docker_run.sh p0|p1|p2|p3|d0|d1|d2|d3 [start|stop|status|logs|--dry-run]}"
case "$node" in p[0-3]|d[0-3]) ;; *) echo "Invalid node: $node" >&2; exit 2 ;; esac
shift
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$project_dir/$node/service.sh" "$@"
