#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
check_settings
mkdir -p "$LOG_DIR"
response="$LOG_DIR/smoke-$(date +%Y%m%d-%H%M%S).json"
payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"请用中文简短介绍你自己。"}],"max_tokens":256,"temperature":0,"stream":false}' "$SERVED_MODEL_NAME")
curl --noproxy '*' --fail-with-body --silent --show-error --connect-timeout 10 --max-time 600 \
    "http://$P0_IP:$PROXY_PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    --data "$payload" -o "$response"
"$PYTHON_BIN" - "$response" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding='utf-8'))
if data.get('error') or not data.get('choices'):
    raise SystemExit(f'FAIL: {path}: {data}')
message = data['choices'][0].get('message', {})
if not (message.get('content') or message.get('reasoning_content') or message.get('tool_calls')):
    raise SystemExit(f'FAIL: no generated content; inspect {path}')
print(json.dumps(data, ensure_ascii=False, indent=2))
print(f'PASS: generation returned through the P/D proxy. Saved: {path}')
print('Confirm matching P and D rank logs for KV transfer and absence of errors before benchmarking.')
PY
