#!/usr/bin/env bash
# Sourced by the entry scripts; all paths are relative to this folder.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
set -a
source "$SCRIPT_DIR/cluster.env"
source "$SCRIPT_DIR/node.env"
set +a
ip_key="${NODE_NAME}_IP"
LOCAL_IP=${!ip_key}
if [[ "$ROLE" == P ]]; then
    DP_SIZE=$P_DP_SIZE
    TP_SIZE=$P_TP_SIZE
    DP_ADDRESS=$LOCAL_IP
else
    DP_SIZE=$D_DP_SIZE
    TP_SIZE=$D_TP_SIZE
    DP_ADDRESS=$D0_IP
fi
LOG_DIR="$LOG_ROOT/$NODE_NAME"
export LOCAL_IP DP_SIZE TP_SIZE DP_ADDRESS LOG_DIR
PYTHON_BIN=${PYTHON_BIN:-python3}

check_settings() {
    local key value
    for key in P0_IP P1_IP D0_IP D1_IP NIC_NAME; do
        value=${!key}
        if [[ -z "$value" || "$value" == *CHANGE_ME* ]]; then
            echo "Configure $key in cluster.env/node.env first." >&2
            return 1
        fi
    done
    local address octet i j
    local -a octets addresses=("$P0_IP" "$P1_IP" "$D0_IP" "$D1_IP")
    for address in "${addresses[@]}"; do
        [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
            echo "Invalid IPv4 address: $address" >&2; return 1;
        }
        IFS=. read -r -a octets <<< "$address"
        for octet in "${octets[@]}"; do
            (( 10#$octet <= 255 )) || { echo "Invalid IPv4 address: $address" >&2; return 1; }
        done
    done
    for ((i=0; i<4; i++)); do
        for ((j=i+1; j<4; j++)); do
            [[ "${addresses[i]}" != "${addresses[j]}" ]] || {
                echo 'P0/P1/D0/D1 must have distinct IP addresses.' >&2; return 1;
            }
        done
    done
    [[ "$NUM_SPECULATIVE_TOKENS" =~ ^[0-9]+$ ]] && (( NUM_SPECULATIVE_TOKENS >= 5 )) || {
        echo 'DSpark requires the same speculative-token count >= 5 on P and D.' >&2; return 1;
    }
    (( DP_SIZE_LOCAL * TP_SIZE == 8 )) || {
        echo 'Local DP x TP must equal eight NPU devices.' >&2; return 1;
    }
    (( DP_RANK_START + DP_SIZE_LOCAL <= DP_SIZE )) || return 1
}

print_command() { printf '%q ' "$@"; printf '\n'; }

check_host_paths() {
    case "$SCRIPT_DIR" in /data1|/data1/*) ;; *)
        echo 'Upload this node folder under /data1 before starting.' >&2; return 1;;
    esac
    [[ "$MODEL_PATH" == /data1/* && -f "$MODEL_PATH/config.json" ]] || {
        echo "MODEL_PATH must point to weights under /data1: $MODEL_PATH/config.json" >&2; return 1;
    }
    [[ "$LOG_ROOT" == /data1/* ]] || { echo 'LOG_ROOT must be under /data1.' >&2; return 1; }
}

check_container_owner() {
    local owner
    owner=$(docker inspect --format '{{ index .Config.Labels "dsv4-pd.node" }}' "$CONTAINER_NAME")
    [[ "$owner" == "$NODE_NAME" ]] || {
        echo "Container $CONTAINER_NAME was not created for $NODE_NAME by this package. Inspect it or set a different CONTAINER_NAME; no container was removed." >&2
        return 1
    }
}
