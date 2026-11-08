#!/usr/bin/env bash
# Internal container entry point; start via service.sh on the host.
set -euo pipefail
cd /opt/glm51
exec >> "${RUN_LOG:?RUN_LOG is required}" 2>&1
printf '[%s] Starting %s; MTP_TOKENS=%s\n' "$(date -Is)" "${NODE_ID:?}" "${MTP_TOKENS:-3}"
python -c 'from importlib.metadata import version; print("vllm:",version("vllm")); print("vllm-ascend:",version("vllm-ascend"))'
exec python -u launch_online_dp.py "$@"
