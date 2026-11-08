#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
dry_run=0
if [[ ${1:-} == --dry-run ]]; then dry_run=1; shift; fi
(( $# == 0 )) || { echo 'Usage: bash docker_run.sh [--dry-run]' >&2; exit 2; }
if (( ! dry_run )); then
    check_settings
    check_host_paths
    mkdir -p "$LOG_DIR/ascend"
    if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        check_container_owner
        configured_image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
        [[ "$configured_image" == "$IMAGE" ]] || { echo 'Existing container image differs from IMAGE; use a new CONTAINER_NAME.' >&2; exit 1; }
        if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME") != true ]]; then
            docker start "$CONTAINER_NAME"
        fi
        echo "Container ready: $CONTAINER_NAME (reused)."
        exit 0
    fi
fi
cmd=(docker run -itd --name "$CONTAINER_NAME" --shm-size "$SHM_SIZE"
     --net host --privileged=true --stop-timeout 30 --env TZ=Asia/Shanghai
     --label "dsv4-pd.node=$NODE_NAME")
for device in {0..7}; do cmd+=(--device "/dev/davinci$device"); done
cmd+=(--device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc
      -v /usr/local/dcmi:/usr/local/dcmi
      -v /usr/local/Ascend/driver/tools/hccn_tool:/usr/local/Ascend/driver/tools/hccn_tool
      -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi
      -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64
      -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info:ro
      -v /etc/ascend_install.info:/etc/ascend_install.info:ro
      -v /etc/hccn.conf:/etc/hccn.conf:ro
      -v /data1/:/data1/ -v "$LOG_DIR/ascend:/root/ascend/log" -w "$SCRIPT_DIR"
      "$IMAGE" bash)
if (( dry_run )); then print_command "${cmd[@]}"; else exec "${cmd[@]}"; fi
