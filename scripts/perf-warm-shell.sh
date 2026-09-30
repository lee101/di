#!/bin/sh
# usage: scripts/perf-warm-shell.sh <di-binary> <label>
# Per-call latency of the shell tool with the real dotfiles mirrored into a scratch HOME.
# Call 1 pays the login shell once (snapshot generation); the rest are warm.
bin=$(readlink -f "$1")
cd "$(dirname "$0")/.." || exit 1
for i in 1 2 3; do
  line=$(MIRRORHOME=1 CALLS=${CALLS:-30} TOOL_CMD="echo hi" FX_BIN=$bin bun scripts/perf-bench.ts go 2>&1 | rg '^\{')
  ms=$(echo "$line" | sed -E 's/.*"ms":([0-9]+).*/\1/')
  echo "$2 run$i total_ms=$ms per_call_ms=$((ms / ${CALLS:-30}))"
done
