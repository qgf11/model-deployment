#!/usr/bin/env bash
# Shared host-side implementation, copied into every standalone node folder.
set -euo pipefail

host_main() {
    local action="${1:-start}"
    local script_dir image data_dir model_dir container_name stamp log_name run_log
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    image="${IMAGE:-quay.io/ascend/vllm-ascend:v0.23.0.post1}"
    data_dir="${HOST_DATA_DIR:-/data1}"
    model_dir="${MODEL_DIR:-${MODEL_PATH:-/data1/GLM-5.1-w8a8}}"
    container_name="glm51-post1-${NODE_ID}${CONTAINER_SUFFIX:-}"
    local latest_file="$data_dir/${PROCESS_KIND}_glm51_${NODE_ID}.latest"
    case "$action" in
        logs)
            [[ -f "$latest_file" ]] || { echo "No log record: $latest_file" >&2; return 1; }
            IFS= read -r log_name < "$latest_file"
            [[ "$log_name" == "${PROCESS_KIND}_glm51_${NODE_ID}_"*.log && "$log_name" != */* ]] || return 1
            exec tail -n 100 -F "$data_dir/$log_name"
            ;;
        status)
            docker inspect --format '{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}}' "$container_name"
            return
            ;;
        stop)
            local owner
            owner="$(docker inspect --format '{{index .Config.Labels "glm51.post1.node"}}' "$container_name")" || return 1
            [[ "$owner" == "$NODE_ID/$PROCESS_KIND" ]] || { echo "Refusing to stop an unrelated container: $container_name" >&2; return 1; }
            docker stop --time 60 "$container_name"
            return
            ;;
        start|--dry-run) ;;
        *) echo "Usage: bash ${PROCESS_KIND}.sh [start|stop|status|logs|--dry-run]" >&2; return 2 ;;
    esac
    case "${MTP_TOKENS:-3}" in 0|3) ;; *) echo "MTP_TOKENS must be 0 or 3" >&2; return 2 ;; esac
    [[ "$data_dir" == /* && "$model_dir" == /* ]] || { echo "Data/model directories must be absolute Linux paths" >&2; return 2; }
    stamp="$(date +%Y%m%d_%H%M%S)_$$"
    log_name="${PROCESS_KIND}_glm51_${NODE_ID}_${stamp}.log"
    run_log="/data1/$log_name"
    # Older Docker may lack --pull support and the docker-init binary.
    # The local image is checked below before running the container.
    local -a command=(docker run --detach --rm
        --name "$container_name" --label "glm51.post1.node=$NODE_ID/$PROCESS_KIND"
        --network host --stop-timeout 60
        --mount "type=bind,source=$data_dir,target=/data1"
        --mount "type=bind,source=$script_dir,target=/opt/glm51,readonly"
        --workdir /opt/glm51
        --env "NODE_ID=$NODE_ID" --env "RUN_LOG=$run_log" --env LOG_DIR=/data1
        --env PYTHONUNBUFFERED=1 --env "MTP_TOKENS=${MTP_TOKENS:-3}"
        --env "SERVED_MODEL_NAME=${SERVED_MODEL_NAME:-glm-pro}")
    if [[ "$PROCESS_KIND" == service ]]; then
        # D3 only: its old Docker seccomp profile blocks CANN file access.
        # Disabling this container's filter passed the ZerosLike smoke test.
        command+=(--security-opt seccomp=unconfined)
        command+=(--shm-size=512g
            --mount "type=bind,source=$model_dir,target=/data1/GLM-5.1-w8a8,readonly"
            --env MODEL_PATH=/data1/GLM-5.1-w8a8/)
        local n
        for n in {0..7}; do command+=(--device "/dev/davinci$n"); done
        command+=(--device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc
            --mount type=bind,source=/usr/local/Ascend/driver,target=/usr/local/Ascend/driver,readonly
            --mount type=bind,source=/usr/local/dcmi,target=/usr/local/dcmi,readonly
            --mount type=bind,source=/etc/ascend_install.info,target=/etc/ascend_install.info,readonly
            --mount type=bind,source=/usr/local/bin/npu-smi,target=/usr/local/bin/npu-smi,readonly)
    fi
    command+=("$image" bash "$CONTAINER_ENTRY" "${node_args[@]}")
    if [[ "$action" == --dry-run ]]; then
        printf '%q ' "${command[@]}"
        printf '\nHost log: %s/%s\n' "$data_dir" "$log_name"
        return 0
    fi
    command -v docker >/dev/null || { echo "Docker is required on the host" >&2; return 1; }
    [[ -d "$data_dir" ]] || { echo "Missing host data directory: $data_dir" >&2; return 1; }
    if [[ "$PROCESS_KIND" == service ]]; then
        [[ -f "$model_dir/config.json" ]] || { echo "Model config.json missing: $model_dir" >&2; return 1; }
    fi
    docker info >/dev/null || return 1
    if docker container inspect "$container_name" >/dev/null 2>&1; then
        echo "Container already exists: $container_name. Use this script's status/stop commands first." >&2
        return 1
    fi
    docker image inspect "$image" >/dev/null || {
        echo "Import/pull this image first: $image" >&2; return 1;
    }
    # Also verifies that the host log directory is writable before starting.
    : > "$data_dir/$log_name"
    "${command[@]}" || return 1
    printf '%s\n' "$log_name" > "$latest_file"
    printf 'Container launched: %s (this does not mean the model is ready)\n' "$container_name"
    printf 'Host log: %s/%s\nView logs: bash %s/%s.sh logs\n' "$data_dir" "$log_name" "$script_dir" "$PROCESS_KIND"
}
