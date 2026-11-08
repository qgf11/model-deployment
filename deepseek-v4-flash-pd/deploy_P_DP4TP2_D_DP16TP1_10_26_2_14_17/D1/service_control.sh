#!/usr/bin/env bash
# Internal container helper; public scripts call it from the host.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
action=${1:-}
service=${2:-}
case "$service" in
    engine) target=start_in_container.sh ;;
    proxy) [[ "$NODE_NAME" == P0 ]] || exit 2; target=proxy_in_container.sh ;;
    *) echo 'Expected service engine or proxy.' >&2; exit 2 ;;
esac
mkdir -p "$LOG_DIR"
pidfile="$LOG_DIR/$service.pid"
case "$action" in
    start)
        command -v flock >/dev/null || { echo 'flock is required in the container.' >&2; exit 1; }
        exec 9>"$LOG_DIR/$service.lock"
        if ! flock -n 9; then
            echo "$NODE_NAME $service is already running; see $LOG_DIR/latest-$service.log"
            exit 0
        fi
        check_settings
        if [[ "$service" == engine ]]; then
            # Match the allocator used by run_dp_template.sh for engine processes.
            jemalloc=/usr/lib/aarch64-linux-gnu/libjemalloc.so.2
            if [[ -f "$jemalloc" ]]; then
                LD_PRELOAD="$jemalloc${LD_PRELOAD:+:$LD_PRELOAD}" \
                    "$PYTHON_BIN" -c 'import vllm, vllm_ascend; import mooncake.engine'
            else
                "$PYTHON_BIN" -c 'import vllm, vllm_ascend; import mooncake.engine'
            fi
        else
            "$PYTHON_BIN" -c 'import httpx, fastapi, uvicorn; import vllm_ascend.patch.recompute_proxy'
        fi
        logfile="$LOG_DIR/$service-$(date +%Y%m%d-%H%M%S-%N).log"
        # fd 9 transfers the service lock to the launched process.
        nohup bash -c 'echo "$$" > "$1"; exec bash "$2"' _ "$pidfile" "$SCRIPT_DIR/$target" \
            > "$logfile" 2>&1 < /dev/null &
        child=$!
        ln -sfn "$(basename -- "$logfile")" "$LOG_DIR/latest-$service.log"
        sleep 1
        if ! kill -0 "$child" 2>/dev/null; then
            echo "$NODE_NAME $service exited during startup. Log: $logfile" >&2
            tail -n 60 "$logfile" >&2
            exit 1
        fi
        echo "$NODE_NAME $service launched in the background (PID $child). Initialization is still pending."
        echo "Host log: $logfile"
        echo "Follow: tail -F $LOG_DIR/latest-$service.log"
        ;;
    stop)
        exec 9>"$LOG_DIR/$service.lock"
        if flock -n 9; then echo "$NODE_NAME $service is stopped."; exit 0; fi
        [[ -f "$pidfile" ]] || { echo "Missing $pidfile; inspect the service before stopping." >&2; exit 1; }
        read -r child < "$pidfile"
        [[ "$child" =~ ^[0-9]+$ ]] && (( child > 1 )) || exit 1
        kill -TERM "$child" 2>/dev/null || true
        for ((i=0; i<25; i++)); do
            if flock -n 9; then echo "$NODE_NAME $service stopped."; exit 0; fi
            sleep 1
        done
        echo "$NODE_NAME $service has not stopped after 25 seconds; retain logs and inspect it." >&2
        exit 1
        ;;
    *) echo 'Usage: service_control.sh start|stop engine|proxy' >&2; exit 2 ;;
esac
