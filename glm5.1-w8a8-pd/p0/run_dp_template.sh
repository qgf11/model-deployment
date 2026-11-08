#!/usr/bin/env bash
# vLLM-Ascend 0.23.0.post1 + vLLM 0.23.0; run through service.sh.
set -euo pipefail
if [[ $# -ne 7 ]]; then
    echo "Usage: $0 devices port dp_size dp_rank dp_address dp_rpc_port tp_size" >&2
    exit 2
fi
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
engine_id="$(( 0 + $4 ))"
mtp_tokens="${MTP_TOKENS:-3}"
spec_args=()
case "$mtp_tokens" in
    3) spec_args=(--speculative-config '{"num_speculative_tokens":3,"method":"deepseek_mtp","enforce_eager":true}') ;;
    0) ;; # Must be set consistently on ALL eight hosts.
    *) echo "MTP_TOKENS must be 0 or 3" >&2; exit 2 ;;
esac
nic_name="bond1"
local_ip="192.0.2.10"
export HCCL_OP_EXPANSION_MODE="AIV"
export HCCL_IF_IP=$local_ip
export GLOO_SOCKET_IFNAME=$nic_name
export TP_SOCKET_IFNAME=$nic_name
export HCCL_SOCKET_IFNAME=$nic_name
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE=1000
export ASCEND_AGGREGATE_ENABLE=1
export ASCEND_TRANSPORT_PRINT=1
export ACL_OP_INIT_MODE=1
export VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT=480
export VLLM_RPC_TIMEOUT=3600000
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=30000
export ASCEND_RT_VISIBLE_DEVICES=$1
export VLLM_ASCEND_ENABLE_MLAPO=0
export VLLM_ASCEND_ENABLE_NZ=1
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib"
export VLLM_USE_V1=1
export TASK_QUEUE_ENABLE=1
export CPU_AFFINITY_CONF=1
export HCCL_EXEC_TIMEOUT=600
export HCCL_INTRA_ROCE_ENABLE=1
export HCCL_CONNECT_TIMEOUT=1800

cmd=(vllm serve "${MODEL_PATH:-/data1/GLM-5.1-w8a8/}" \
    --host 0.0.0.0 \
    --enable-expert-parallel \
    --port $2 \
    --data-parallel-size $3 \
    --data-parallel-rank $4 \
    --data-parallel-address $5 \
    --data-parallel-rpc-port $6 \
    --tensor-parallel-size $7 \
    --enable-chunked-prefill \
    --enable-prefix-caching \
    --seed 1024 \
    --served-model-name "${SERVED_MODEL_NAME:-glm-pro}" \
    --max-model-len 141312 \
    --additional-config \
    '{"multistream_overlap_shared_expert": true, "recompute_scheduler_enable": false, "ascend_compilation_config": {"enable_npugraph_ex": true, "fuse_qknorm_rope": false, "fuse_muls_add": true}, "enable_flashcomm1": true}' \
    --max-num-batched-tokens 4096 \
    --trust-remote-code \
    --max-num-seqs 32 \
    --quantization ascend \
    --gpu-memory-utilization 0.96 \
    --async-scheduling \
    --enforce-eager \
    --enable-auto-tool-choice \
    --tool-call-parser glm47 \
    --reasoning-parser glm45 \
    --kv-transfer-config \
    '{"kv_connector": "MooncakeConnectorV1", "kv_role": "kv_producer", "kv_port": 30000, "engine_id": "'"$engine_id"'", "kv_connector_extra_config": {"prefill": {"dp_size": 4, "tp_size": 8}, "decode": {"dp_size": 8, "tp_size": 4}}}' \
    "${spec_args[@]}"
)
if [[ "${DRY_RUN:-0}" == 1 ]]; then
    printf '%q ' "${cmd[@]}"
    printf '\n'
    exit 0
fi
log_dir="${LOG_DIR:-/data1}"
mkdir -p "$log_dir"
"${cmd[@]}" 2>&1 | tee "$log_dir/glm_${NODE_ID:-node}_dp${4}_port${2}_$(date +%Y%m%d_%H%M%S)_$$.log"
