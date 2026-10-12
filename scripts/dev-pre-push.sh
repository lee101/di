#!/usr/bin/env bash
# Pre-push gate for this repository.
#
# 1. Autofmt: every Zig source that is part of the push is formatted with
#    `zig fmt`. When formatting changes one of those files, the change is staged
#    and the push stops, so unformatted code never reaches a branch and no
#    commit is rewritten behind the author's back. Sources that are not being
#    pushed are left alone, so unrelated work in the tree stays untouched.
# 2. Secret scan: every commit about to be pushed is scanned with gitleaks using
#    .gitleaks.toml.
#
# Enable it for this checkout with:
#   git config core.hooksPath "$(git rev-parse --show-toplevel)/scripts/git-hooks"
# and keep a copy of this file at scripts/git-hooks/pre-push.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

remote="${1:-}"
zero=0000000000000000000000000000000000000000
ranges=()
range_count=0

while read -r _local_ref local_sha _remote_ref remote_sha; do
  [ "$local_sha" = "$zero" ] && continue
  if [ "$remote_sha" = "$zero" ]; then
    ranges+=("$local_sha --not --remotes=${remote}")
  else
    ranges+=("${remote_sha}..${local_sha}")
  fi
  range_count=$((range_count + 1))
done

if [ "$range_count" -eq 0 ]; then
  echo "pre-push: nothing to push" >&2
  exit 0
fi

find_zig() {
  for candidate in "${ZIG:-}" "$HOME/.zvm/bin/zig" "$(command -v zig || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Collect the Zig sources that the push touches.
pushed_zig=()
pushed_zig_count=0
for range in "${ranges[@]}"; do
  read -r -a revisions <<< "$range"
  while IFS= read -r -d '' file; do
    case "$file" in
      *.zig)
        if [ -f "$file" ]; then
          pushed_zig+=("$file")
          pushed_zig_count=$((pushed_zig_count + 1))
        fi
        ;;
    esac
  done < <(git log --format= --name-only -z "${revisions[@]}" -- src/)
done

if [ "$pushed_zig_count" -eq 0 ]; then
  echo "pre-push: no Zig sources in this push" >&2
else
  zig="$(find_zig || true)"
  if [ -z "$zig" ]; then
    echo "pre-push: no zig found; skipping autofmt (install Zig or set ZIG=/path/to/zig)" >&2
  else
    formatted=()
    for file in "${pushed_zig[@]}"; do
      output="$("$zig" fmt "$file")" || exit 1
      [ -z "$output" ] || formatted+=("$output")
    done
    dirty=()
    dirty_count=0
    for file in "${pushed_zig[@]}"; do
      if ! git diff --quiet -- "$file"; then
        dirty+=("$file")
        dirty_count=$((dirty_count + 1))
      fi
    done
    if [ "$dirty_count" -gt 0 ]; then
      git add -- "${dirty[@]}"
      echo "pre-push: zig fmt reformatted: ${formatted[*]-}" >&2
      echo "pre-push: those files are staged. Commit them and push again. Nothing was pushed." >&2
      exit 1
    fi
  fi
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "pre-push: gitleaks is required for push protection (install it or unset this hook)." >&2
  exit 1
fi

status=0
for range in "${ranges[@]}"; do
  echo "pre-push: gitleaks scanning ${range}" >&2
  gitleaks git --log-opts="$range" --redact --no-banner . || status=1
done

exit $status
