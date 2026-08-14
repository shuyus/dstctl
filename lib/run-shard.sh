#!/usr/bin/env bash
# 在 screen/tmux/fifo 中启动单个世界进程
# 编码: UTF-8
set -euo pipefail
PIDFILE="$1"
BINDIR="$2"
BIN="$3"
shift 3
cd "$BINDIR"
echo $$ >"$PIDFILE"
export LD_LIBRARY_PATH="${BINDIR}:${BINDIR}/lib64:${BINDIR}/lib32:${LD_LIBRARY_PATH:-}"
exec "$BIN" "$@"
