# di and op: efficiency and capability comparison

Source audit, 2026-09-27. Compared this checkout with the local Oh My Pi fork
at `../op/packages/coding-agent`. Similar capabilities do not imply identical
arguments, UI, provider coverage or behavior. Full feature parity is not yet
established.

| Area | di | op comparison / remaining work |
| --- | --- | --- |
| Read, write, edit, glob | Native tools with bounded output and permission checks | Core workflow exists in both; op additionally has archive/PDF helpers and specialized edits. |
| Content search | Literal `grep_files`, native fallback, tracked-file `git grep` | op has native regex search and AST search/edit; di can use shell `rg`, but that is not native regex or AST parity. |
| Semantic local search | Optional `fuzzy_search` adapter for existing zbed indexes; read-only protocol, workspace/grep permissions, bounded time/output | Separate from literal/regex search. Does not start a daemon or index automatically; no comparative speed benchmark yet. |
| Shell | Captured commands, persistent TTY sessions, cancellation, deadlines, retained results | Core workflow exists in both. Command and argument schemas differ. |
| Search command efficiency | Conservative automatic translation in clean full-access captured shells; otherwise direct rg guidance | op's `bash-interceptor.ts` redirects selected shell patterns to dedicated tools. It does not provide general grep-to-rg equivalence. |
| Concurrent tools | Read-only and subagent groups, ordered results; scheduler batches capped at eight | Avoids one native thread per call for an arbitrarily large model-generated group. Mutations remain behind earlier reads. This does not cap the lifetime of child agents. |
| Session continuity | Saved sessions, compaction and steering | Compare provider and resume behavior using identical deterministic scenarios before claiming parity. |
| Extensions | Skills, MCP capabilities, subagents, ACP and SDK surfaces | Shared categories; no claim of op extension API compatibility. |
| Web and images | Fetch, search, grounded search, vision and image reads | op additionally has browser/computer automation and image generation tools. MCP or shell access is not native tool parity. |
| Specialized developer tools | General shell and file tools | op has LSP, debugging, GitHub helpers, checkpoints and memory tools without corresponding entries in di's builtin registry. |

## Automatic search translation contract

Only clean bash/zsh captured execution authorized by full-access (`yolo`)
authority is eligible. The original authority fingerprint must match before
rewriting. Configured rules, remembered or interactive exact approvals, auto
reviews, direct-only grants, user startup profiles and TTYs are left unchanged.
The captured runtime retains the effective command in its execution metadata.

Supported searches explicitly specify recursive text mode and filename
formatting: `grep -ranFH needle src`, for example. Accepted flags are `r`, `R`,
`a`, `F`, `n`, `H` and `h`; unsupported flags leave the command unchanged.
Without `F`, only simple alphanumeric/space/underscore/hyphen literals qualify.
Fixed patterns and paths also pass a conservative shell-syntax filter.

The rg invocation disables config, searches hidden and ignored files, disables
encoding conversion, retains line/filename formatting, uses one worker and
follows directory symlinks only for `R`. File traversal order and error wording
are not guaranteed identical across the two executables. Missing rg falls back
to the original command; a search failure or no-match result does not rerun it.
Binary detection, regexes, pipelines, expansions, count/quiet/list modes and
stdin searches remain grep. This is deliberately not a global grep alias.

The existing `file-tool-paths.test.ts` owns deterministic runtime coverage and
retains its PGSO training classification. Unit tests cover syntax boundaries,
allocation failures, exact approvals, and bounded scheduling.

## Next parity work

1. Add native regex search with fixtures for Unicode, ignored/hidden files,
   context/count modes, cancellation and bounded output.
2. Compare edit recovery, tool schemas and resume behavior using identical
   deterministic scenarios in both agents.
3. Prioritize browser lifecycle cleanup and LSP/AST support according to actual
   workflows. Avoid starting idle browser or indexer daemons by default.
4. Measure startup, idle CPU, peak RSS, tool latency and model round trips on
   the same workload after host memory pressure clears. No speedup is claimed
   from the pressured shared-host measurements.
