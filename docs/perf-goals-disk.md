# Goal mode, disk, RAM and shell performance

Measured on Linux x86_64, Zig 0.16 ReleaseFast builds, against a fake gateway
(`scripts/perf-bench.ts`, `scripts/perf-suite.sh`). "base" is commit e8bf60d7,
"new" is this branch. Wall times are noisy on a shared host; syscall counts
(`strace -f -c`) are deterministic.

## 1. Goal mode

`di ask --auto-next-goal "<objective>"` reuses the auto-next loop in
`src/core/cli/cli_ask.zig`; the goal logic lives in `src/core/goal/`.

- Store: one compact JSON line per workspace, `~/.fx/goals/<hash of workspace>.json`,
  replaced atomically. No sqlite. Fields: objective, status, budgets, tokens/turns/seconds
  used, session id, stall counters, last progress signature, last progress line.
- Resume: `di ask --auto-next-goal` with no prompt resumes the saved goal, in the saved
  session when it still exists (otherwise a fresh session that carries the last progress
  line). A different objective replaces the goal.
- Signal protocol (text, no extra tool, so no tool-description tokens): every reply ends with
  `GOAL: continue|complete|blocked`, `PROGRESS: <line>`, and `EVIDENCE:` or `BLOCKER:`.
  `complete` without evidence is ignored. `blocked` needs two consecutive reports.
- Loop guards: an unchanged normalized `PROGRESS` line, or no protocol lines and no tool calls,
  is no progress; three in a row stop the loop as `stalled`. Token, turn and time budgets stop it
  as `budget-limited` (the last turn is told to wrap up). Five consecutive failed turns stop it
  with the goal saved. An external `/goal pause` or `/goal clear` is honored after the current turn.
- Per-iteration status line on stderr, for example
  `[goal] #2 continue | tok 16/100.0k | turns 2/5 | 0s | wrote parser`.
- Prompt size: follow-up turns send about 250 bytes (turn number, last progress, remaining
  budget, protocol reminder) instead of re-sending the previous summary as `--auto-next-steps`
  does.
- Exit status: the CLI surface maps every nonzero code to 1. 0 means `complete`; the status line
  and the goal file carry the exact state (`blocked`, `budget_limited`, `stalled`, `paused`).
- TUI: `/goal OBJECTIVE [--tokens N] [--turns N] [--time D]`, `/goal`, `/goal pause`,
  `/goal resume`, `/goal clear`, `/goal budget ...`. The continuation is driven from the worker
  turn-finished event (`src/core/goal/goal_tui.zig`), using the reply text captured at that event.

Comparison with codex goals: codex persists in sqlite and asks the model to call
`update_goal`; this uses a file, no tool schema, evidence-gated completion, a two-report blocked
rule, stall detection by progress signature, and a per-iteration status line. Codex has an
`update_plan` integration and a `budget_limited` steering turn that this does not.

Verification: `tests/e2e/goal-mode.test.ts` (7 CLI scenarios), `tests/e2e/tui-goal.test.ts`
(2 TUI scenarios in tmux), 20 unit tests in `src/core/goal/`.

## 2. Disk

Measurements of the real `~/.fx` (copy, 26.3 MB by `du`):

| item | before | after |
| --- | --- | --- |
| file-index caches (4 files) | 16.7 MB | 0.95 MB (zstd, 17.5x) |
| session tool results (80 cold files) | 4.4 MB | 3.1 MB |
| `~/.fx` total (apparent) | 23.3 MB | 6.1 MB |
| `~/.fx` total (`du`, 4K blocks) | 26.3 MB | 8.6 MB |

Found by measurement:

- Sessions are already append-only (`events.jsonl`), not rewritten. Session events are not
  fsynced per event.
- Per tool call about 20 fsyncs: session directory after each atomic replace, `usage-v2.json`
  (about 2.4 per call), `recovery.json` (about 1.8), `usage-recovery`, the tool-result file and
  directory, the command replay file and directory, `usage.jsonl`. These are crash-recovery
  contracts, so they were not weakened here.
- Each tool output is stored three times: the truncated result artifact (16 KB), the full command
  replay file, and a preview in `events.jsonl`. For 30 calls of `seq 1 3000`: 28 KB per call.
- 14 of 246 tool-result files in the real store are exact duplicates (1.2 MB). Session files must
  have `nlink == 1`, so hardlink dedupe is rejected by the store; content-addressed sharing would
  need a store format change and is not done.
- The 17 MB file-index cache (65 percent of `~/.fx`) was uncompressed JSON.

Shipped:

- `src/core/shared/compress.zig`: zstd through a runtime-loaded `libzstd.so.1` (no build-time
  dependency, `FX_DISABLE_LIBZSTD=1` disables it), zlib deflate from std when libzstd is absent,
  std zstd decoding for reading (works without libzstd). Never returns output larger than input.
- File index cache format v2 (codec byte, SHA-256 of the payload, compressed body). v1 files still
  load; the background rescan rewrites them as v2, and `di storage compact` migrates all of them.
- `di storage stats|compact|restore` (hidden command). `compact` archives `tool-results/*` of
  sessions idle for 7 days (`--older-than`), skipping live owners, as `NAME.fxz` (header, SHA-256,
  codec, data). The original is removed only after the archive was written durably and decoded back
  to identical bytes. `restore` reverses it; `diff -r` of the real sessions tree after
  compact and restore was empty. Nothing is deleted without a verified copy.
- Lazy restore: `SessionChildCapability.openFileReadOnly` and `stat` restore an archived tool
  result on first access, so cold sessions stay readable and resumable.
- `di ask` command output batching (see section 4).

Tests: `compress.zig` (3), `cold_archive.zig` (4), `file_index_cache.zig` (v1 to v2 migration),
`session_child_store.zig` (lazy restore), `tests/e2e/storage.test.ts`.

Not done: coalescing the usage/recovery fsyncs, session event dedupe by content address, log
rotation (the only log, `logs/trace.log`, is 14 KB), compressing `events.jsonl` and command replay
files (session discovery and the replay store read those directly).

## 3. RAM

Peak RSS is small and flat. `di ask` with 10 tool calls per turn for 400 requests
(`echo hi`): 18.6 MB at request 50, 26.3 MB at request 400 in both base and new
(about 20 KB per request of retained history, no step changes). 30 calls of `seq 1 40000`
(290 KB output each): 26 MB. 20 calls of `seq 200000` (1.3 MB each): 20 MB. Large outputs are
already streamed to a spool file and only a 64 KB projection is kept, so no code change was made
for RAM. The new output batching buffer is bounded to 16 KB. A long-session growth that
does exist: per-request wall time grows about 50 percent between request 50 and 400 (46 to 68 ms),
consistent with per-turn session reload; not addressed.

## 4. Shell and tool path

Profile of one `shell` call (`echo hi`, default profile): re-exec of the supervisor
(`/proc/self/exe __fx_foreground_session__`), `bash --login` (17.4 ms on a scratch HOME, 18 ms with
the real dotfiles, versus 4.2 ms for `--noprofile`), about 20 fsyncs (about 8 ms), 1 ms poll loop with a
`/proc` scan per iteration, and one `writev` per output line to stderr.

Shipped:

1. Command output batching in `di ask` (`cli_ask.zig`): chunks are coalesced up to 16 KB or 50 ms
   and flushed before any other stderr write and at tool completion.
2. Warm user shell (`src/core/terminal/login_snapshot.zig`, hooked in `command_runner.zig`): the
   `bash --login` result (aliases, functions, shopt, exported-environment delta with PATH edits
   applied around the caller's PATH) is captured once and cached in `~/.fx/cache/shell-snapshot`
   (key: shell, HOME/USER/LANG, startup file mtimes; 12 h TTL; reused across processes). Later
   commands run `env ... BASH_ENV=<snapshot> bash --noprofile -O expand_aliases -c`. Any failure
   falls back to the login shell; `FX_SHELL_SNAPSHOT=0` disables it; zsh is unchanged. Not captured:
   non-exported shell variables and `set -o` options.

Results (30 calls per run unless noted):

| workload | metric | base | new |
| --- | --- | --- | --- |
| `seq 1 200000` x20 | wall per call | 567 ms | 96 ms |
| `seq 1 200000` x20 | total syscalls | 6,833,668 | 86,417 |
| `seq 1 200000` x20 | `writev` | 4,013,134 | 14,736 |
| `seq 1 200000` x20 | `openat` | 542,286 | 9,809 |
| `seq 1 40000` | wall per call | 161 ms | 55 ms |
| `seq 1 40000` | total syscalls | 1,875,409 | 51,481 |
| `seq 1 40000` | `writev` | 1,203,614 | 4,066 |
| `seq 1 3000` | wall per call | 60 ms | 50 ms |
| `echo hi` | wall per call | 42 ms | 33 ms |
| `echo hi` | total syscalls | 67,881 | 31,303 |
| `echo hi`, real dotfiles mirrored | wall per call | 40 to 45 ms | 29 to 31 ms |
| `echo hi`, profile with `sleep 0.5` x10 | wall per call | 553 ms | 94 ms (one 0.5 s capture) |

The warm shell gain scales with the profile cost: a profile that takes 5 s per login (the
`sh -lc` case reported for one host) is paid once instead of per command. On this host
`getent passwd` is `/bin/bash` and di runs `bash --login`; only `sh -lc` (dash) reads the 6845-line
`~/.profile` (4987 ms measured), and di selects bash for unsupported login shells, so di itself does
not hit that path.

Already present, verified: read-only tool calls (`read_file`, glob, grep, fuzzy search, web) run in
parallel groups of up to 8 (`parallel_execution.zig`); a direct no-shell route exists for read-only
commands under the `clean` profile (`router.zig`, `direct_command.zig`).

Not done:

- Independent `shell` calls in one response still run sequentially: 4 calls of `sleep 0.3` take
  1386 ms versus 392 ms for one (`scripts/perf-batch.ts`). Running them in parallel needs
  per-call command-output lifecycles in the transcript, which assumes one open command output.
- In-process `cat`/`ls`/`pwd`/`wc`/`head`/`tail`: the direct route already avoids the shell for the
  `clean` profile, and the default `user` profile requires the shell route by design (aliases and
  profile PATH), so new builtins would change semantics for little gain over the warm shell.
- Adaptive backoff of the 1 ms completion poll (which still scans `/proc` every iteration) was not
  attempted: it changes when leftover descendants are noticed, and the `command_runner`
  process-tree tests that guard that failed at the base commit (14 failures on this host); they
  pass after merging main (full `zig build test` on the merged branch: 9754 passed, 19 skipped,
  0 failed), so this is a candidate for a follow-up.
- A persistent warm shell process (one bash reused across commands) was replaced by the snapshot
  approach because commands need their own process group, pipes and cancellation.

## Reproducing

```
zig build -Doptimize=ReleaseFast -p /tmp/new
OUT=/tmp/perf STRACE=1 scripts/perf-suite.sh /tmp/new/bin/di new
scripts/perf-warm-shell.sh /tmp/new/bin/di new
FX_BIN=/tmp/new/bin/di PARALLEL=4 bun scripts/perf-batch.ts
FX_BIN=/tmp/new/bin/di CALLS=10 TOOL_CMD="echo hi" MAXREQ=400 bun scripts/perf-bench.ts --auto-next-goal "loop"
```
