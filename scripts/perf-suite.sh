#!/bin/sh
# usage: scripts/perf-suite.sh <di-binary> <label>
# Runs the fake-gateway workload against a binary and prints one metrics block.
bin=$(readlink -f "$1")
label=$2
out=${OUT:-/tmp/perf-suite}
mkdir -p "$out"
cd "$(dirname "$0")/.." || exit 1
run() { # name calls cmd
  name=$1
  calls=$2
  cmd=$3
  FX_BIN=$bin CALLS=$calls TOOL_CMD="$cmd" WRAP="/usr/bin/time -v -o $out/$label-$name.time" \
    bun scripts/perf-bench.ts "go" 2>&1 | rg '^\{' > "$out/$label-$name.json"
  ms=$(sed -E 's/.*"ms":([0-9]+).*/\1/' "$out/$label-$name.json")
  rss=$(rg "Maximum resident" "$out/$label-$name.time" | awk '{print $NF}')
  cs=$(rg "Voluntary context" "$out/$label-$name.time" | awk '{print $NF}')
  home=$(sed -E 's/.*"home":"([^"]+)".*/\1/' "$out/$label-$name.json")
  du=$(du -sk "$home/.fx" | cut -f1)
  echo "$label $name calls=$calls wall_ms=$ms per_call_ms=$((ms / calls)) rss_kb=$rss ctxsw=$cs fx_kb=$du"
  if [ -n "$STRACE" ]; then
    FX_BIN=$bin CALLS=$calls TOOL_CMD="$cmd" WRAP="strace -f -c -o $out/$label-$name.strace" \
      bun scripts/perf-bench.ts "go" > /dev/null 2>&1
    awk '$NF=="writev"||$NF=="write"||$NF=="openat"||$NF=="fsync"||$NF=="read"||$NF=="clock_nanosleep"||$NF=="getdents64"||$NF=="total" {printf "  %s=%s", $NF, $4} END{print ""}' "$out/$label-$name.strace"
  fi
}
run echo 30 "echo hi"
run seq3k 30 "seq 1 3000"
run seq40k 30 "seq 1 40000"
run seq200k 20 "seq 1 200000"
