#!/usr/bin/env python3
"""Launch this node's DP ranks; a failed local rank fails the launcher."""
import argparse
import os
from pathlib import Path
import signal
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dp-size", type=int, required=True)
    parser.add_argument("--tp-size", type=int, required=True)
    parser.add_argument("--dp-size-local", type=int, required=True)
    parser.add_argument("--dp-rank-start", type=int, default=0)
    parser.add_argument("--dp-address", required=True)
    parser.add_argument("--dp-rpc-port", type=int, default=10521)
    parser.add_argument("--vllm-start-port", type=int, default=6606)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not (0 < args.dp_size_local <= args.dp_size
            and 0 <= args.dp_rank_start <= args.dp_size - args.dp_size_local
            and args.tp_size > 0 and args.dp_size_local * args.tp_size == 8):
        parser.error("Expected a valid DP range and exactly eight local NPU devices")
    directory = Path(__file__).resolve().parent
    env = os.environ.copy()
    if args.dry_run:
        env["DRY_RUN"] = "1"
    children = []

    def stop(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, stop)
    try:
        for local_rank in range(args.dp_size_local):
            devices = ",".join(str(n) for n in range(
                local_rank * args.tp_size, (local_rank + 1) * args.tp_size))
            command = [shutil.which("bash") or "bash", "./run_dp_template.sh", devices,
                       str(args.vllm_start_port + local_rank), str(args.dp_size),
                       str(args.dp_rank_start + local_rank), args.dp_address,
                       str(args.dp_rpc_port), str(args.tp_size)]
            if args.dry_run:
                subprocess.run(command, cwd=directory, env=env, check=True)
            else:
                children.append(subprocess.Popen(
                    command, cwd=directory, env=env, start_new_session=True))
        while children:
            codes = [child.poll() for child in children]
            if any(code is not None and code != 0 for code in codes):
                return 1
            if all(code is not None for code in codes):
                return 0
            time.sleep(1)
        return 0
    finally:
        # Each rank has its own process group, including bash, tee and workers.
        for child in children:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for child in children:
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                pass
        for child in children:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
