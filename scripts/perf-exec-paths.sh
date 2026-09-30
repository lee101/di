#!/bin/sh
# usage: scripts/perf-exec-paths.sh <di-binary>
# Shows which shell tool commands take the direct (no-shell) route by counting execs.
bin=$(readlink -f "$1")
cd "$(dirname "$0")/.." || exit 1
for c in "pwd" "ls" "cat big.txt" "wc -l big.txt" "head -n 3 big.txt" "rg -n xxx big.txt" "echo hi" "true" "printf x" "seq 1 3"; do
  NOYOLO=${NOYOLO:-1} FX_BIN=$bin CALLS=2 TOOL_CMD="$c" WRAP="strace -f -e trace=execve -o /tmp/perf-exec.txt" bun scripts/perf-bench.ts go >/dev/null 2>&1
  n=$(rg -c 'execve' /tmp/perf-exec.txt)
  first=$(rg 'execve' /tmp/perf-exec.txt | sed -n 2p | cut -c1-100)
  echo "$c => $n execs; $first"
done
