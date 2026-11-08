#!/usr/bin/env python3
"""Launch external DP ranks, retain per-rank logs, and propagate failures/signals."""
import argparse
import datetime
import os
from pathlib import Path
import signal
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dp-size', 'tp-size', 'dp-size-local', 'dp-rank-start', 'dp-rpc-port', 'vllm-start-port'):
        parser.add_argument('--' + name, type=int, required=True)
    parser.add_argument('--dp-address', required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if min(args.dp_size, args.tp_size, args.dp_size_local) < 1:
        parser.error('DP and TP sizes must be positive')
    if args.dp_rank_start < 0 or args.dp_rank_start + args.dp_size_local > args.dp_size:
        parser.error('Local DP ranks exceed global DP size')
    if args.dp_size_local * args.tp_size != 8:
        parser.error('This package targets exactly eight NPUs per A2 node')
    root = Path(__file__).resolve().parent
    children = []
    handles = []
    stop_signal = None

    def handle_signal(signum, _frame):
        nonlocal stop_signal
        stop_signal = signum

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    try:
        if not args.dry_run:
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            log_dir = Path(os.environ['LOG_DIR']) / stamp
            log_dir.mkdir(parents=True)
            print(f'Rank logs: {log_dir}', flush=True)
        for local_rank in range(args.dp_size_local):
            rank = args.dp_rank_start + local_rank
            devices = ','.join(str(i) for i in range(local_rank * args.tp_size, (local_rank + 1) * args.tp_size))
            cmd = [shutil.which('bash') or 'bash', './run_dp_template.sh', devices,
                   str(args.vllm_start_port + local_rank), str(args.dp_size), str(rank),
                   args.dp_address, str(args.dp_rpc_port), str(args.tp_size)]
            env = os.environ.copy()
            env['DRY_RUN'] = '1' if args.dry_run else '0'
            if args.dry_run:
                subprocess.run(cmd, cwd=root, env=env, check=True)
            else:
                log = (log_dir / f'rank-{rank}.log').open('ab', buffering=0)
                handles.append(log)
                children.append(subprocess.Popen(cmd, cwd=root, env=env, stdout=log,
                                                 stderr=subprocess.STDOUT, start_new_session=True))
        if args.dry_run:
            return 0
        while stop_signal is None:
            for proc in children:
                code = proc.poll()
                if code is not None:
                    print(f'Rank process {proc.pid} exited ({code}); stopping sibling ranks.', flush=True)
                    return code if code > 0 else 1
            time.sleep(0.5)
        return 128 + stop_signal
    finally:
        for proc in children:
            # A failed leader can leave workers alive in its process group.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 15
        for proc in children:
            try:
                proc.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
            # Reap surviving workers even if their group leader already exited.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for log in handles:
            log.close()


if __name__ == '__main__':
    raise SystemExit(main())
