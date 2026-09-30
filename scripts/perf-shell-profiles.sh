#!/bin/sh
# usage: scripts/perf-shell-profiles.sh <di-binary> [label]
# Per-call latency of the shell tool by profile and command (30 calls each, fake gateway).
bin=$(readlink -f "$1")
cd "$(dirname "$0")/.." || exit 1
calls=${CALLS:-30}
for opts in user clean; do
  for c in "echo hi" "cat big.txt" "rg -n x big.txt" "ls"; do
    line=$(PROFILE=$opts NOYOLO=1 CALLS=$calls TOOL_CMD="$c" FX_BIN=$bin bun scripts/perf-bench.ts go 2>&1 | rg '^\{')
    ms=$(echo "$line" | sed -E 's/.*"ms":([0-9]+).*/\1/')
    echo "${2:-bin} profile=$opts cmd=[$c] per_call_ms=$((ms / calls)) total_ms=$ms"
  done
done
