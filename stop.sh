#!/bin/sh
# Kill stray jig processes. jig は one-shot CLI なので通常は即終了するが、
# tty の stdin を待ったまま放置された invocation を掃除するのに使う。
# Safe to run when nothing is running (no-op)。
#
#   ./stop.sh
set -e

pkill -x jig          2>/dev/null || true
pkill -f '/bin/jig'   2>/dev/null || true

remaining="$(pgrep -fl jig | grep -vE 'stop\.sh|run\.sh|grep' || true)"
if [ -n "$remaining" ]; then
    echo "warning: some jig instances survived:" >&2
    echo "$remaining" >&2
    exit 1
fi
echo "stopped: all jig instances"
