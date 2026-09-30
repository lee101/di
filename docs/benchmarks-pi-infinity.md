# di vs pi-infinity: overhead, behaviour, gaps

Measured 2026-09-30 on Linux x86_64. Baseline is the main checkout at 9e4616fe (ReleaseSafe). "After" is branch `worktree-agent-aec88a64bf8fca63c`. Models: `gpt-6.1-sol` (Codex ChatGPT login) and `stealth/space-bunny-alpha` (OpenPaths, `env -u OPENPATHS_API_KEY`). Reproduction scripts live outside the repo (request capture via `FX_E2E_OPENAI_CODEX_RESPONSES_URL` and `FX_E2E_OPENPATHS_CHAT_URL` loopback mocks; tasks via `di ask --full-access --no-save --json`).

## 1. Measurements

### Static

| Metric | di before | di after | pi-infinity 0.84.3 |
| --- | --- | --- | --- |
| Binary size (stripped ReleaseSafe) | 12.7 MB | 12.7 MB | node + dist (n/a) |
| Startup (`--version`, median of 6) | 3-4 ms | 2-3 ms | 1380 ms (`node cli.js --version`) |
| Codex request body, trivial prompt | 31,672 B / 6,547 tok | 21,088 B / 4,565 tok | n/a |
| OpenPaths request body, trivial prompt | 31,738 B / 6,541 tok | 21,158 B / 4,562 tok | n/a |
| `tools` array | 21,138 B (17 tools) | 12,711 B (15 tools) | 2,712 B (read, bash, edit, write) |
| `instructions` / system prompt | 11,004 B | 8,758 B (base prompt 7,291 to 5,697 B) | 1,850 B |

Tokens are `o200k_base` counts of the whole request JSON. Fixed per-turn overhead fell 30% (about 1,980 tokens per turn). pi-infinity remains roughly 4x smaller per turn because it ships 4 tools and a tiny prompt. The `instructions` figure here still includes two host-specific skills and the web_search guidance.

### Four tasks (di ask, fresh temp dir each, checked by script)

Tasks: (1) read and edit a constant, (2) grep and summarize, (3) rename a function across 4 files, (4) run a failing test and fix it.

| Model | Metric (sum over 4 tasks) | Before | After |
| --- | --- | --- | --- |
| gpt-6.1-sol | input tokens | 105,557 | 77,079 (-27%) |
| gpt-6.1-sol | output tokens | 1,252 | 1,211 |
| gpt-6.1-sol | model steps | 14 | 15 |
| gpt-6.1-sol | wall | 121 s | 103 s |
| gpt-6.1-sol | pass | 4/4 | 4/4 |
| space-bunny-alpha | input tokens | 162,068 | about 103,600 (-36%) |
| space-bunny-alpha | output tokens | 2,064 | about 2,100 |
| space-bunny-alpha | model steps | 31 | about 29 |
| space-bunny-alpha | wall | 49 s | about 30 s |
| space-bunny-alpha | pass | 4/4 | 4/4 (one early-stop sample, see below) |

Per task after/before input tokens, gpt-6.1-sol: t1 19.9k/23.5k, t2 12.4k/18.1k, t3 23.4k/33.0k, t4 21.3k/31.0k. Task 3 on space-bunny was rerun 3 times each: before 43.4k/51.3k/62.7k input (12/14/15 steps, 16 to 18 s); after 33.0k/32.1k/33.0k (10/12/9 steps, 10 to 11 s), 3/3 pass. In the first "after" pass the model once ended its turn after five reads without editing (announced "let me read them before editing" then stopped); that is a model turn-ending quirk, not reproduced in 3 reruns. Wall times are dominated by provider latency (Codex about 5 to 8 s per step) and are noisy; token counts are the reliable signal. Effort was not the lever: `--effort low` on gpt-6.1-sol changed output tokens by under 5% and wall time within noise, so the provider default effort is kept.

pi-infinity headless runs were skipped: `pinf` has no `gpt-6.1-sol` or `stealth/space-bunny-alpha` in its catalog, and the only configured key (`openai` provider) is rejected with HTTP 401.

Observed behaviours: models rarely batch tool calls on their own (space-bunny issued 5 sequential `read_file` calls in a rename task; gpt-6.1-sol prefers `shell` with `rg`/`sed`).

## 2. Feature comparison

| Area | di | pi-infinity | Delta |
| --- | --- | --- | --- |
| Tools | read_file, glob_files, grep_files (literal only), fuzzy_search, edit_file, write_file, shell (run/interact/stop with owned sessions and tty), web_fetch, web_search, gemini_search, think, todo, skill/install_skill/capability_search/mcp_*, subagent, vision, read_tool_result | read, bash, edit, write, grep, find, ls (+extensions) | di has far more surface; each unused tool costs tokens every turn |
| Edit format | one exact `old_string` per call | `edits[]` with several disjoint replacements per call, matched against the original file | di needs one call (one round trip) per hunk |
| Tool-call parallelism | model may emit parallel calls; runtime runs only a leading run of read-only calls concurrently (`parallel_execution.zig`); writes and shell are serial | parallel by default, per-tool `sequential` opt-out, file-mutation queue serializes writes to the same path | di does not parallelize edits to distinct files or read-only shell |
| Context compaction | request cost measured and calibrated per model, automatic and manual compaction planning | threshold compaction (reserve 16k, keep-recent 20k) plus branch summarization | roughly at par; no branch summaries in di |
| Prompt caching | before: none explicit; Codex sent `session-id` header only. Now: Codex `prompt_cache_key` = session id for saved sessions | `prompt_cache_key`, `sessionId`, `cacheRetention` for Codex/OpenAI, cache_control for Anthropic | di still sends no `cache_control` for Anthropic routes via OpenPaths/OpenRouter and no key for `--no-save` runs |
| Model and effort switching | `--model`, `--effort`, `--fast`, `/model` menu, per-child model/effort for subagents | `--model` with `:thinking`, `--thinking`, Ctrl+P model cycling | at par |
| Sessions | saved sessions, `--resume`, recovery checkpoints, `--no-save` | `--continue`, `--resume`, `--fork`, `--session-dir`, HTML export | di lacks fork and export |
| Autonomy | `--auto-next-steps`, `--auto-next-idea` | same flags | at par |
| Startup | 3 ms native | about 1.4 s Node | di wins by 400x |

## 3. Changes made

1. Tool schema diet (`src/builtins/tools.zig`): every built-in description rewritten without the "When to use / When NOT to use" boilerplate, the repeated 190-character path description reduced to one short form that keeps the external-path and permission semantics, and verbose parameter descriptions trimmed. Tools array 21.1 KB to 12.7 KB.
2. System prompt (`src/builtins/system_prompt.md`): 7,291 to 5,697 bytes, merged redundant bullets, added two efficiency rules (batch independent tool calls in one turn; do not re-read a file after a successful edit). Size cap test tightened from 8 KiB to 6 KiB.
3. Capability tool gating (`src/core/tooling/tool_projection.zig`, `src/core/cli/cli_ask.zig`): `Options.mcp_available` and `skills_available` hide `mcp_select_tool` and `mcp_features` when no MCP server is configured, and `capability_search` when there are neither MCP servers nor skills. Wired for `di ask` and its subagents only; the TUI and ACP keep the full set because servers can be added mid-session.
4. Empty MCP catalog (`src/core/mcp/model_catalog.zig`): with no servers the prompt block is now the 3-line `<mcp_servers><none /></mcp_servers>` instead of about 500 bytes of guidance for a capability that cannot be used.
5. Prompt-cache routing (`src/gateway/openai_codex.zig`, `src/core/agent/stream_provider.zig`, `src/core/agent/runtime/orchestrator.zig`): `RequestData.session_id` is plumbed to the Codex request builder, which now emits `prompt_cache_key` when a real session id exists (verified on the wire for a saved session; omitted for `--no-save`).
6. Prefix stability: the static prefix (instructions, tools) contains no per-turn data; only the turn context block (workspace, date at day granularity) varies. The tool order is fixed by the registry.
7. Tests: new unit tests for the Codex cache key (present, null, empty), tool gating combinations, empty MCP catalog rendering, prompt batching rules; existing description and byte-exact hash tests and four e2e string expectations updated.

Verification: `zig build test` passes (9,715 of 9,748) except the `core.execution.command_runner` and `core.execution.managed_execution` tests (owned by another agent, failing identically before these changes). The Bun e2e files for gateway lifecycle and web_search fail in this environment with the baseline binary as well (exit code 1 within about 300 ms), so the four edited e2e string expectations are unverified here. Built binary exercised end to end on both routes with the four tasks above and wire-level request captures.

## 4. Remaining gaps and ideas

- Multi-hunk `edit_file` (`edits[]`) would cut round trips on refactors, the single largest step-count driver.
- Parallel execution of edits to distinct paths and of read-only shell commands.
- Anthropic `cache_control` breakpoints on OpenPaths/OpenRouter routes; a stable synthetic cache key for `--no-save` runs.
- Further schema cuts: `shell` (2.0 KB, three-variant oneOf), `todo` (1.5 KB), `read_tool_result` (1.1 KB), `think` and `gemini_search` could be opt-in; `fuzzy_search` (0.8 KB) is advertised even when zbed is not configured (an e2e test depends on that).
- Per-model reasoning-effort defaults were not changed: measurements showed no token or wall-time benefit from `low` on gpt-6.1-sol.
- pi-infinity task runs need models present in its catalog and a valid provider key.
