#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
(( $# == 7 )) || { echo 'Expected devices port dp_size dp_rank dp_address dp_rpc_port tp_size' >&2; exit 2; }
export ASCEND_RT_VISIBLE_DEVICES=$1
export HCCL_IF_IP=$LOCAL_IP
export GLOO_SOCKET_IFNAME=$NIC_NAME
export TP_SOCKET_IFNAME=$NIC_NAME
export HCCL_SOCKET_IFNAME=$NIC_NAME
export OMP_PROC_BIND=false OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_OP_EXPANSION_MODE=AIV TASK_QUEUE_ENABLE=1 HCCL_BUFFSIZE=1024
export VLLM_RPC_TIMEOUT=3600000 VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=30000
export HCCL_EXEC_TIMEOUT=204 HCCL_CONNECT_TIMEOUT=1500
export VLLM_PREFIX_CACHE_RETENTION_INTERVAL=4096
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
export NO_PROXY='*' no_proxy='*'
if [[ -f /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ]]; then
    export LD_PRELOAD="/usr/lib/aarch64-linux-gnu/libjemalloc.so.2${LD_PRELOAD:+:$LD_PRELOAD}"
fi
if [[ "$ROLE" == P ]]; then
    kv_role=kv_producer
    batch=$P_MAX_BATCHED_TOKENS
    seqs=$P_MAX_SEQS
    memory=$P_MEMORY_UTILIZATION
    additional='{"enable_cpu_binding":true,"enable_dsa_cp":true,"enable_flashcomm1":true}'
    role_args=(--enforce-eager)
else
    kv_role=kv_consumer
    batch=$D_MAX_BATCHED_TOKENS
    seqs=$D_MAX_SEQS
    memory=$D_MEMORY_UTILIZATION
    additional='{"ascend_compilation_config":{"enable_npugraph_ex":true,"enable_static_kernel":false},"enable_cpu_binding":true,"multistream_overlap_shared_expert":true,"recompute_scheduler_enable":true}'
    if [[ "$D_ENFORCE_EAGER" == 1 ]]; then
        role_args=(--enforce-eager)
    else
        role_args=(--compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY"}')
    fi
fi
kv_config=$(printf '{"kv_connector":"MooncakeHybridConnector","kv_role":"%s","kv_port":"%s","engine_id":"%s","kv_connector_extra_config":{"prefill":{"dp_size":%s,"tp_size":%s},"decode":{"dp_size":%s,"tp_size":%s}}}' \
    "$kv_role" "$KV_PORT" "$ENGINE_ID" "$P_DP_SIZE" "$P_TP_SIZE" "$D_DP_SIZE" "$D_TP_SIZE")
spec_config=$(printf '{"method":"dspark","num_speculative_tokens":%s,"enforce_eager":true}' "$NUM_SPECULATIVE_TOKENS")
cmd=(vllm serve "$MODEL_PATH" --host 0.0.0.0 --port "$2"
     --data-parallel-size "$3" --data-parallel-rank "$4" --data-parallel-address "$5"
     --data-parallel-rpc-port "$6" --tensor-parallel-size "$7" --enable-expert-parallel
     --seed 1024 --served-model-name "$SERVED_MODEL_NAME" --max-model-len "$MAX_MODEL_LEN"
     --max-num-batched-tokens "$batch" --max-num-seqs "$seqs" --block-size 32
     --async-scheduling --no-disable-hybrid-kv-cache-manager --trust-remote-code
     --gpu-memory-utilization "$memory" --quantization ascend
     --model-loader-extra-config '{"enable_multithread_load":true,"num_threads":128}'
     --tokenizer-mode deepseek_v4 --tool-call-parser deepseek_v4 --enable-auto-tool-choice
     --reasoning-parser deepseek_v4 --speculative-config "$spec_config"
     --kv-transfer-config "$kv_config" --additional-config "$additional" "${role_args[@]}")
if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf 'ASCEND_RT_VISIBLE_DEVICES=%q ' "$ASCEND_RT_VISIBLE_DEVICES"
    print_command "${cmd[@]}"
    exit 0
fi
echo "[$NODE_NAME] DP rank=$4, devices=$ASCEND_RT_VISIBLE_DEVICES, HTTP=$2, KV base=$KV_PORT, engine=$ENGINE_ID"
exec "${cmd[@]}"
