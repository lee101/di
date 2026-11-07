# Contributing to fx

fx is open source and developed in public at [vercel-labs/fx](https://github.com/vercel-labs/fx). The fx team at Vercel maintains it and makes most changes, and pull requests from outside contributors are welcome and go through the same CI checks. Only maintainers can push branches to the repository, add labels, or start optional CI runs. Outside contributors work from a fork, and a maintainer handles those steps for them.

Code conventions live in [AGENTS.md](AGENTS.md): which module owns which behavior, how fx uses Zig 0.17, how permissions and tests are structured, and the rules coding agents follow. Read it before you change code, whether you write the change yourself or with a coding agent.

## Report a problem

Run `/feedback` inside fx to open the feedback form, or [open an issue](https://github.com/vercel-labs/fx/issues/new/choose) with the bug report template. Describe what you did, what you expected, and what happened instead. If something looks wrong in your terminal, `/trace` copies a private diagnostic trace that you can attach. Issues are public, so review the trace and remove secrets before you post it.

Report security vulnerabilities through the [contact page](https://fx.sh/contact), not in a public issue.

## Set up a checkout

You need:

- [Zig 0.17.0](https://ziglang.org/download/), the version CI builds with. Check `zig version` before you build, because an older Zig fails inside `build.zig` with errors such as `no field or member function named 'poisonCache'` that don't mention the version.
- [Bun](https://bun.sh) and [tmux](https://github.com/tmux/tmux) for the end-to-end tests.
- [hyperfine](https://github.com/sharkdp/hyperfine), if you want to run the startup benchmark locally.

The unit tests and most end-to-end tests don't call a model. To try a change that does, sign in as the [README](README.md#quick-start) describes or set `AI_GATEWAY_API_KEY`.

Clone the repository, or your fork if you're an outside contributor, and build fx:

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build
./zig-out/bin/fx
```

Test your changes with `./zig-out/bin/fx` from your checkout. A bare `fx` runs whichever copy comes first on your `PATH`, which is usually an installed release that doesn't include your change.

fx keeps its settings and sessions in `~/.fx`, and on macOS it stores API keys and OAuth credentials in your Keychain. To try a change against an empty profile without touching your own, give fx a temporary home directory and turn off Keychain storage:

```bash
HOME="$(mktemp -d)" FX_DISABLE_KEYCHAIN=1 ./zig-out/bin/fx
```

## Make a change

Start each change from the latest `main`, and keep each pull request to one change. Put unrelated formatting, renames, and cleanup in their own pull requests, so each one can be reviewed and reverted on its own.

Before you build a feature, answer the questions in the [Adding a Feature](AGENTS.md#adding-a-feature) section of AGENTS.md. They ask which module owns the behavior, what its typed contract is, whether it needs persistence or JSON output, which docs and tests land with it, and how its end-to-end tests are classified for PGSO. If you can't answer them yet, settle the design before you write code. Outside contributors can propose a design in an issue first.

These rules apply to every change:

- `src/main.zig` only wires runtimes together. Feature logic and state belong to the module that owns them.
- Sensitive tool behavior goes through the permission system in `src/core/permissions/permissions.zig`. Don't add a path around it.
- fx has no dependencies outside the Zig standard library. Talk to the maintainers before you add one.
- Don't commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`.
- Don't commit home-directory paths, real team IDs, or personal project slugs. `scripts/check-public-surface.sh` rejects them in CI, so use `/Users/example/` in fixtures.
- Don't document behavior that doesn't exist yet.

If a coding agent helps with your change, point it at AGENTS.md. Any prose the agent writes for your contribution, including pull request titles and descriptions, commit messages, documentation, and issues, must follow the `technical-writer` skill in `.fx/skills/technical-writer/`.

## Test your change

Run the tests that cover your change, build fx, and then use `./zig-out/bin/fx` to exercise the change yourself. Tests don't always start the full runtime, attach a terminal, or spawn background threads, so a passing suite can still miss a startup crash or a rendering regression. Confirm that fx didn't abort, that stderr is clean, and that the behavior matches what you'll describe in the pull request.

```bash
zig fmt src/
zig build
zig build test
cd tests/e2e
bun install
bun test cli.test.ts
```

Zig unit tests sit in `test` blocks inside the source file they cover, and `zig build test` runs all of them. CI checks formatting with `zig fmt --check src/`. The end-to-end tests run the binary at `zig-out/bin/fx`, so build before you run them. Run only the end-to-end files that cover your change, because CI runs the whole suite on every push. The `tui-*` files drive fx inside tmux.

### Add an end-to-end test file

Every root `tests/e2e/*.test.ts` file needs an entry in the first two files below, and in the third only when it branches on the platform. CI fails when a required entry is missing or stale:

| File | Entry |
| --- | --- |
| `scripts/pgso/corpus.json` | Exactly one classification: training, verification-only, or intentional exclusion |
| `tests/e2e/ci-shard-weights.json` | A weight that balances the four CI shards |
| `tests/e2e/macos-platform-tests.json` | Needed only when the file branches on `process.platform` or `platform()` being `darwin` or `linux` |

The corpus drives the macOS arm64 PGSO build, which profiles fx on the training files, optimizes the code they exercise for speed, and compiles the functions they show to be cold for size. Classify a file as training when it covers common or performance-sensitive behavior. Use verification-only for correctness, recovery, security, or rare behavior that the build must pass without treating it as hot. Use an intentional exclusion only for coverage that is nondeterministic, needs the network or credentials, involves sound, or tests the harness itself, and record the reason. A test added to an existing file inherits that file's classification, and removing a file means removing its entries.

### Reproduce a rendering bug

fx prints into your terminal's scrollback instead of taking over the screen, so many rendering bugs appear only at certain sizes or after a resize. Reproduce a bug at the lowest layer that catches it:

1. A Zig unit test in `src/ui/resize_tests.zig` drives the transcript renderer against an in-process virtual terminal, with no TTY or signals. These tests are the fastest and run in `zig build test`.
2. A tmux test in `tests/e2e/tui-resize.test.ts` covers bugs that need a real terminal and a real `SIGWINCH`. `tests/e2e/tmux-helpers.ts` provides `resizeWindow`, `capturePaneGrid`, and `capturePaneEscapes`.
3. A recorded tape captures a session someone has already seen go wrong. Run fx with `FX_RECORD=/tmp/bug.fxtape`, or with `FX_DEBUG_RECORD=1` to write a private tape under `~/.fx/recordings/`, then replay it without a terminal:

   ```bash
   ./zig-out/bin/fx replay /tmp/bug.fxtape
   ./zig-out/bin/fx replay /tmp/bug.fxtape --golden /tmp/bug.txt
   ```

   `--golden` writes the final screen to a file that you can check in as the expected result.

When a tmux test or a tape exposes a bug, reproduce it as a Zig unit test before you fix it, so the fix lands with its regression test.

### Fuzz a parser

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

If you can manage labels on `vercel-labs/fx`, which takes triage access or higher, apply the label when you open the PR. For a mixed PR, choose the label that best describes why the PR exists. If you contribute from outside the organization, you cannot add labels and do not need to: a maintainer applies the label during review, so open your PR and mark it ready as usual. Keep the title as a clean imperative sentence and do not add bracketed type prefixes such as `[bug]` or `[improvement]`.

Requesting extra CI also needs access: the `ci:macos` label takes triage access, and `gh workflow run` takes write access. If you need the macOS checks, a PGSO run, or another on-request run and cannot start it yourself, ask in your PR and a maintainer will start it.

If an AI coding agent writes any of your contribution's prose, including the PR title and description, commit messages, documentation, and issues, it must use the `technical-writer` skill in `.fx/skills/technical-writer/`.

## Repo Shape

* `src/main.zig`: composition root only

* `src/core/`: contracts, runtimes, config, sessions, permissions, MCP, skills

* `src/tools/`: built-in tool implementations

* `src/ui/`: terminal rendering, event loop, input, transcript

* `src/gateway/`: AI Gateway client transport

* `.fx/skills/`: optional fx-native workspace-level skill root

* `skills/`: optional shared workspace-level skill root

## Collaboration Rules

Before adding a new feature, answer these first:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?
6. How is its deterministic E2E owner classified for macOS arm64 PGSO?

If that is unclear, stop and define it first.

### PGSO corpus ownership

Classify every root `tests/e2e/*.test.ts` file in
`scripts/pgso/corpus.json`. Put common or performance-sensitive behavior in
training. Put important correctness, recovery, security, and rare behavior in
verification-only. Exclude only nondeterministic, live-network, credentialed,
sound-related, or harness-only coverage, and record the reason.

Tests added to an existing file inherit its classification. Reconsider that
classification when a feature changes the file's product role, and remove stale
entries when deleting a feature or E2E owner. Normal PR CI rejects missing,
duplicate, stale, and unclassified files without running the full PGSO gate.

## Configuration and State

Config precedence (highest wins):

1. Environment variables such as `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
2. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.fx/settings.json` top-level (profile global settings)
4. `<workspace>/.fx.json` (committed project defaults)
5. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `sandbox`, `max_agent_steps`, `max_tool_result_bytes`, and `context`. Profile-owned keys such as `provider`, `providers`, `models`, `model`, `effort`, `fast_mode`, `slash_menu_categories`, `startup_scrollback`, `prompt_history`, `statusLine`, `skill_match_fuzzy`, `first_call_tool_choice`, `auto_upgrade`, `auto_compact_percent`, `auto_compact_warm_percent`, `update_channel`, `permission_mode`, `permission`, and `skill_symlink_authorities` are ignored from project config before their values are parsed.

`skill_symlink_authorities` is an array of absolute directories that symlinked skills may resolve into, such as an app bundle or `/nix/store`. It is read at startup, a workspace override replaces the global list, and its entries are combined with the colon-separated `FX_SKILL_SYMLINK_AUTHORITIES` environment variable.

Runtime state lives under `~/.fx/`:

* `~/.fx/sessions/<session-id>/session.json`

* `~/.fx/sessions/<session-id>/background/`

* `~/.fx/sessions/<session-id>/subagent/`

* `~/.fx/sessions/<session-id>/logs/`

Sessions are global and portable across workspaces. Each session tracks a `workspace_root` that updates when resumed from a different directory.

Subagent children are internal ordinary sessions with their own `~/.fx/sessions/<child-id>/` directory and history. The parent owns one bounded `subagent/children.json` registry; each child carries only an immutable owner marker. Child sessions are hidden from ordinary session discovery and cannot be resumed directly. A first `subagent.message` creates a named persistent child for that parent; later messages continue it, and optional instructions replace only its child-specific system overlay.

## Skills

There are two distinct skill categories in `fx`:

* `fx` roots that belong to the product itself: `.fx/skills`, `skills/`, `~/.fx/skills`

* compatibility roots discovered for other agent installs: `.opencode/skills`, `.codex/skills`, `.claude/skills`, `.agents/skills`, `.claw/skills`, plus their global equivalents

`/skills list` should make that distinction visible to the user.

`/skills add` and `/skills install` install full skill directories into the profile-owned `~/.fx/skills` managed root, not just `SKILL.md`. Workspace `.fx/skills` and `skills/` remain discoverable project-local instructions, not managed install targets.

The interactive agent can also install skills via the `install_skill` tool when the user asks to install one in conversation, including pasted `npx skills add ...` syntax.

## Slack installation testing

`src/core/slack/install.zig` owns workspace bot installation, local credential
persistence, and explicit refresh. The web bridge contract is fixed to
`https://fx.sh/api/slack/install/config`, `/api/slack/install`, and
`/api/slack/oauth/callback`. Employee MCP authentication is separate.

Build with `zig build`, then run `cd tests/e2e && bun test slack-install.test.ts`.
The fixture exercises the freshly built binary and real loopback sockets without
live Slack credentials. `FX_E2E_SLACK_ORIGIN` accepts only an HTTP `127.0.0.1`
origin with a non-privileged port, serving public metadata plus mocked
`/api/oauth.v2.access` and `/api/auth.test` responses. Production uses pinned
Slack endpoints. Local records bind to the bridge origin to prevent fixture
commands from refreshing production credentials. `FX_NO_OPEN_BROWSER=1` prints
the start URL for headless operation; authorization still requires a browser on
the same computer as the listener.

This E2E owner is verification-only in the PGSO corpus because it covers a rare
workspace setup operation and security boundaries. Live Slack authorization and
message attribution are not deterministic tests.

## MCP

Native fx connections use MCP v1 initialization by default over stdio,
Streamable HTTP, and deprecated `2024-11-05` HTTP+SSE. Servers using the newer
`2026-07-28` discovery lifecycle opt in with
`FX_MCP_PROTOCOL_VERSION=2026-07-28` in their configured `environment` map.
The SDK's host-owned client controls its own protocol negotiation. Native
sessions load trusted MCP configuration from the profile:

* `~/.fx/mcp.json`

They also read Claude-compatible workspace configuration from:

* `<workspace>/.mcp.json`

Project `.fx.json` does not define runnable MCP commands, URLs, env, or secrets.
The profile file reads top-level `mcp` and accepts `mcpServers` as a
compatibility alias; `mcp` wins when both exist, and every write uses `mcp`.
Suspicious server-like unsupported keys produce a bounded warning and block
profile mutation instead of being overwritten. The workspace file reads only
top-level `mcpServers`, accepts `command` plus `args`, and is opened as a
bounded no-follow regular file. Profile entries win native name collisions;
ACP request entries win ACP name collisions without deduplicating the request
array. Workspace entries are always optional and never load stored credentials.
Approved workspace `command`, `args`, `env`, and HTTP header values expand
`${VAR}` and `${VAR:-default}` from the fx process environment. Pending and
rejected entries do not read environment values. Missing required variables
leave an approved server unloaded and appear in the `/mcp` and `/mcp list`
menu without exposing values.

Interactive sessions keep pending workspace servers disconnected and request
project trust before any project-defined process or network effect. Pending
resource, prompt, completion, and authentication commands require explicit
`/mcp trust approve <name>` and a retry. Rejected servers remain disconnected.
Choices live only in profile `settings.json` under the canonical workspace key,
using `enabledMcpjsonServers`, `disabledMcpjsonServers`, and
`enableAllProjectMcpServers`. Repository files cannot persist their own
approval. `fx ask` and ACP skip pending workspace servers. Noninteractive users
approve them first with `fx mcp trust approve <name>`; rejected servers remain
disabled.

The core feature surface is Tools, Resources and Resource Templates, Prompts,
Completion, pagination, cache-aware discovery, subscriptions, progress,
cancellation, and form or URL elicitation. Keep modern and legacy protocol
behavior in their existing version-scoped modules.

fx bounds schema size and structure before publication. It accepts schemas
without `$schema`, the canonical JSON Schema 2020-12 declaration, and the
canonical Draft 7 declaration used by legacy SDKs; other declared dialects are
rejected. fx does not resolve network references or evaluate semantic schema
assertions. Servers validate their tool arguments and results.

The interactive surface supports:

* `/mcp`

* `/mcp list` (opens the same server menu)

* `/mcp resource list <server>`

* `/mcp resource templates <server>`

* `/mcp resource read <server> <uri>`

* `/mcp resource complete <server> <uri-template> <variable> [value]`

* `/mcp prompt list <server>`

* `/mcp prompt get <server> <name> [arguments-json]`

* `/mcp prompt complete <server> <name> <argument> [value]`

* `/mcp add <name> <command> [args...]`

* `/mcp add --transport http <name> <url>`

* `/mcp remove <name>`

* `/mcp reload`

* `/mcp auth <name> --open`

* `/mcp logout <name>`

* `/mcp trust approve <name>`

* `/mcp trust reject <name>`

* `/mcp trust approve-all`

* `/mcp trust reset`

* `/mcp path`

The noninteractive MCP surface supports:

* `fx mcp add <name> <command> [args...]`

* `fx mcp add --transport http <name> <url>`

* `fx mcp auth <name>`

* `fx mcp list`

* `fx mcp logout <name>`

* `fx mcp path`

* `fx mcp remove <name>`

* `fx mcp trust approve <name>`

* `fx mcp trust reject <name>`

* `fx mcp trust approve-all`

* `fx mcp trust reset`

The local form saves a stdio command. The HTTP form saves a remote Streamable
HTTP endpoint. List reads effective profile and workspace configuration plus
stored authentication state without connecting servers. Path prints the profile
configuration path. Remove uses the same locked canonical profile writer as
add. Trust updates the canonical workspace entry in profile settings. Auth and
logout run the existing remote credential lifecycle. None of these commands
constructs the TUI or contacts the Gateway.

The default MCP startup timeout is 30 seconds and remains overridable per
server with `startup_timeout_ms`. Exact direct `docker run` stdio commands
without `--cidfile` receive a private cidfile so fx can remove the container
after shutdown or startup failure. An explicit cidfile remains user-owned.

When a stdio server closes its connection before answering `initialize`, for
example because its process exited, the reported failure names the exit code
or signal and includes a bounded, terminal-safe excerpt of the server's stderr
with secrets masked. A startup timeout names the limit that ran out, plus an
earlier launch's exit when there was one, and names the `startup_timeout_ms`
key when that setting set the limit. When a server writes a stdout line that
is not an MCP message, such as a banner, the failure quotes the start of that
line. A startup restart runs only when it could change the outcome: a server
that closed its connection at every offered protocol version is not
restarted, and neither is one whose startup deadline has already passed. A
server that fx stopped because of invalid output still gets its restart. The
model sees the same reason when it searches a named server that is down, or
when a tool call finds its server stopped and the relaunch fails.

MongoDB Atlas Managed MCP configuration service accounts use the OAuth
client-credentials grant. fx does not implement that grant directly. Use
MongoDB's `mongodb-atlas-mcp-remote` stdio wrapper with inherited
`MDB_MCP_API_CLIENT_ID` and `MDB_MCP_API_CLIENT_SECRET` environment variables.
The Atlas App Connection browser flow is user-delegated access and must not be
treated as equivalent to configuration service-account credentials.

Remote authentication supports configured bearer tokens and OAuth credential
discovery, persistence, refresh, scope challenges, and logout. Credential and
private-cache identity changes invalidate prior private state. macOS persists
OAuth credentials in Keychain and migrates the private profile credential file
only after verified publication. If the user account has no default Keychain,
macOS falls back to the same `0600` credential file used on other platforms
under the `0700` profile directory. `FX_DISABLE_KEYCHAIN=1` selects that portable
backend explicitly for deterministic tests and local troubleshooting.

Servers are optional by default. Required startup failures block the first TUI
or `fx ask` model request; optional failures publish a reduced, degraded
capability set. Terminal `fx ask` completes admitted MCP discovery before its
first model request. JSON and other headless asks start required servers first
and defer optional servers until the turn performs an MCP operation or delegates
MCP capability to a child. Server-filtered searches, selected tools, and feature
operations activate only their target; a broad search activates the broader
catalog. Each server owns its startup and recovery progress. Connection deadlines
cover discovery, fallback, and restarts together. Interactive authentication and
logout change only the affected connection. `/mcp` and `/mcp list` open the same
bounded, secret-free menu, which refreshes its live health snapshot while open.
Noninteractive `fx mcp list` renders the health snapshot to stdout.

Search and explicit selection share bounded schema publication. Definitions are
checked against their runtime, connection, catalog, and credential generations
before execution. Tool argument JSON must be bounded and object-shaped; semantic
schema assertions belong to the server. Image results use the shared tool-result,
provider, and versioned history paths. Saved native images use managed result
artifacts that `read_tool_result` can load without repeating the original tool.

`/mcp reload` evaluates a replacement before publication, so invalid config or
a required-server failure leaves the prior runtime callable.

ACP-provided servers are isolated to their owning ACP session. One-off and
persistent subagents receive an immutable, permission-filtered view of the
parent or ACP session's admitted MCP tools, resources, prompts, and completion
capability. Missing, revoked, stale, or closed authority fails before transport.

ACP clients can also serve an MCP server over the ACP connection itself, as
described in the MCP-over-ACP RFD, by declaring
`{"type":"acp","name":"...","serverId":"..."}` in `mcpServers`. fx advertises
`mcpCapabilities.acp` and sends each modern MCP request as an `mcp/message`
request with a fresh logical `requestId`; the client answers with a `result` or
`error` carrier, and timeouts or cancellation send `$/cancel_request`. These
servers connect from the prompt worker at the start of the first turn, because
discovery waits for replies that only the connection reader delivers, so a
server that fails to connect appears in the model's server catalog instead of
failing session setup. Request-scoped `mcp/message` notifications such as
progress are not delivered to operations yet.

## ACP Embedding

`fx acp` extends ACP v1 for clients that embed it. Extensions are read and
written under `_meta.fx`. Start the server with `fx acp --ultrafast` or
`fx acp --no-ultrafast` to set a process-local default request for sessions
created by that server; the request still requires a model that advertises
Ultra eligibility.

* **Client MCP tools stay loaded:** tool schemas from servers in `mcpServers`
  are advertised on every turn within the `mcp_selected_schema_bytes` budget.
  Set `_meta.fx.alwaysLoaded` to `false` on a server entry to load it on demand
  instead. A model call naming a live MCP tool that is not loaded is loaded and
  admitted through the normal MCP permission path instead of failing.
* **Steering:** a `session/prompt` with `_meta.fx.steer` set to `true` while a
  turn runs joins that turn at its next safe boundary and is replayed as a
  `user_message_chunk` whose `_meta.fx.steering.requestId` names the request.
  Its response arrives when that turn ends, with the turn's `stopReason` and
  `_meta.fx.steering` set to `absorbed`. Steering queued when a turn is
  cancelled answers `cancelled` with `dropped`; steering that a turn ended
  without reading returns an error so the client can send it again. Without the
  opt-in, a second prompt keeps the `Prompt already in progress` error.
  `session/load` replays absorbed steering in place with a null `requestId`.
  `initialize` reports support in `agentCapabilities._meta.fx.steering`.
* **Client system prompt:** `session/new` accepts `systemPrompt` text blocks in
  `append` mode, as proposed in the client system prompt RFD, and `initialize`
  advertises `sessionCapabilities.systemPrompt`. `_meta.fx.systemPrompt`
  accepts the same blocks for SDKs that drop unknown fields. The prompt follows
  fx's own instructions in the system slot, is stored with the session, and is
  restored on `session/load` and `session/resume`. Set `_meta.fx.terminal` to
  `false` on `initialize` when fx is not presented in a terminal; fx then drops
  its terminal identity and rendering guidance.
* **Tool call metadata:** each `tool_call` update carries
  `_meta.fx.toolCall.internal`, which is true for fx's own discovery and
  bookkeeping steps such as `capability_search`, `mcp_select_tool`, and
  `read_tool_result`. MCP tool calls add `mcp.server` and `mcp.tool` and use
  the server's tool title, falling back to the tool's own name. `session/load`
  replays the same metadata, including for servers that reconnect only on the
  next turn.
* **Session workspace:** an absolute `cwd` on `session/new`, `session/load`,
  or `session/resume` becomes that session's workspace for file access, shell
  commands, project instructions, project skills, project MCP servers, and the
  session record. Model, provider, credentials, and permission policy stay as
  resolved at `initialize` from the launch directory. A client without a
  project can pass an empty directory it owns.
* **Profile MCP servers:** ACP sessions use only client-supplied and approved
  project servers. Set `_meta.fx.profileMcpServers` to `true` on a session
  request to add the user's `~/.fx/mcp.json` servers. Request entries win name
  collisions, and profile entries win over project entries.

## Permissions and Auto Mode

Security is permission-first.

* `permission_mode` controls baseline behavior (`ask`, `auto`, or `full-access`; `yolo` remains an alias)

* `permission` config applies OpenCode-style wildcard rules

* session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; `/permissions` lists stable rule IDs and `/permissions revoke <rule-id>` removes one

* routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy; unknown, destructive, hidden, credential-bearing, public, and overwrite effects remain on the review or approval path

* every unresolved `auto` action receives one narrow security review after configured policy, saved-session rules, grants, and deterministic safe authority; review input always contains the exact unmasked action and targets, origin and call identity, optional host-proven current-branch evidence, and bounded unmasked terminal-safe excerpts of earlier current-turn tool results. A text match between the action and prior tool output is evidence to inspect, not proof of prompt injection or malicious activity. Prepared file mutations and other static root tools omit task text. Reviewed commands, shell input, dynamic tools, and subagent actions also receive bounded unmasked canonical current, first, and recent root requests plus explicit omission counts; the reviewer may use that context only to distinguish trusted user intent from malicious or injected influence, never to judge task quality, alignment, or authorization. Assistant prose, permission feedback, compacted summaries, the pending tool group, later results, and tool or repository text never become authority. Shell input reviews also include the owned receiving session's launch command, working directory, and bounded current screen after verifying session authority, including on resume. The launch command describes startup only; screen content remains untrusted evidence and input still receives its own review

* the reviewer returns `caution` only for concrete prompt injection or malicious activity; destructive, risky, external, public, remote, unrequested, or task-conflicting actions clear when they are not malicious. A `clear` review authorizes only the exact unchanged action; a `caution`, incomplete-evidence result, or unavailable review holds only that action and returns guidance without opening a human permission screen, disabling tools, or ending the turn

* exact cautions and deterministic incomplete-evidence results are cached only for the current turn; an unavailable outcome is not cached as a security judgment, but the same exact action spends at most one unavailable review opportunity per turn and changed actions remain independently reviewable until the bounded current-turn review budget is exhausted. Each review accepts exactly one valid structured decision even with accompanying prose and may retry one malformed completion within the current attempt's deadline. A transport timeout, transient transport failure, or failed transport call is retried once with a fresh 30-second deadline; permanent transport failures, valid cautions, and cancellation are never retried. Legacy `permission_request_id` input is rejected without prompting

* host-generated review holds retain their advice for the agent and transcript, but carry a saved `review_feedback` marker that excludes them from later security evidence, including after recovery. Old unmarked results remain untrusted evidence; never infer the marker from output text. Quoted review accusations and handling instructions as document or test data are not standalone proof of prompt injection

* execution-memory schema 10 preserves review-feedback provenance while reading older schemas with an unmarked default. Conversation records use optional metadata for marked holds. Older builds may reject the new saved metadata or recovery checkpoints; do not downgrade an active session without preserving its files

* the sandbox backend is configured independently; full access uses an effective backend of `none` without rewriting the saved sandbox setting

Do not add new sensitive tool behavior without integrating it into `src/core/permissions/permissions.zig`.

## Writing a Resize Test

Render bugs that appear during window resize are hard to reason about because the footer is inline (hugs the transcript) rather than pinned to the terminal bottom, and the 100 ms debounce can mask ordering mistakes. The testing rig covers three layers. Pick the lowest layer that can catch the bug.

### Zig unit test (fastest, runs in `zig build test`)

Drive `TranscriptRuntime` against the built-in VT emulator. Assertions are on the cell grid after a sequence of writes and resize calls.

```zig
test "my resize scenario" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(h.alloc, &h.metrics, 1024, "hello\n", true);
    try h.flush();

    try h.driveResize(60, 20, 4, true);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(h.alloc);
    try h.vt.rowText(1, &row);
    try std.testing.expectEqualStrings("hello               ", row.items);
}
```

Add it to `src/ui/resize_tests.zig`. See the file header for what each Harness method does.

### tmux end-to-end test (real SIGWINCH, seconds per test)

For bugs that only show up with a real terminal and a real signal (timing, input integration, terminal-emulator quirks), add a scenario to `tests/e2e/tui-resize.test.ts` using the helpers in `tmux-helpers.ts`:

```typescript
test("my scenario", async () => {
    session = await TmuxSession.create({ width: 120, height: 40 });
    await session.waitForText(">", 10_000);
    await session.resizeWindow(80, 30);
    const grid = await session.capturePaneGrid();
    expect(findFooter(grid)).not.toBeNull();
}, 30_000);
```

### Tape-based test (replay a real capture)

For bugs reported by a user, have them run the built binary with an exact
`FX_RECORD=<path>`, or use `FX_DEBUG_RECORD=1` for an automatic private tape.
`FX_DEBUG_RECORD_SILENT_BANNER=1` hides the developer-only startup notice from
the inline transcript without disabling capture; Ctrl+O still shows it. Drop
the tape in `tests/e2e/tapes/<name>.fxtape` and assert against the built replay
command:

```bash
zig build fuzz -Dfuzz-target=sse_framing               # replay the saved inputs
zig build fuzz -Dfuzz-target=sse_framing --fuzz=200K   # try 200,000 new inputs
```

When the search finds a failure, Zig 0.17 prints `error: test '...'` but still exits with status 0, so read the output. Without a limit, `--fuzz` runs until you stop it and opens Zig's web interface.

The Fuzz workflow fuzzes each target on `main` every night for about 20 minutes, and for two minutes on a pull request that changes the fuzzing setup. When the nightly run finds a failure, it uploads the failing input as an artifact and opens an issue titled `Nightly fuzz failure: <target>`, or comments on that issue if it is already open. To fix the failure, copy the input into `tests/fuzz/corpus/<target>/` and run `zig build fuzz -Dfuzz-target=<target>` to reproduce it. That build uses Debug by default, which adds allocation stack traces to leak reports. Keep the input file in the fix's pull request, so `zig build test` replays it on every pull request after that.

A saved input holds the values the test reads from its `std.testing.Smith`, in order. For example, a test that calls `smith.slice` reads a 4-byte little-endian length and then that many bytes. Inputs that the fuzzer saves are already in this form. Inline seeds go through `@import("fuzz_seed").slices`, which writes each one in this form for a test whose first read is `smith.slice`. A seed written as a plain string would lose its first four bytes to the length.

To add a target, write the fuzz test in the file it covers and add an entry to `tests/fuzz/targets.json`. For a target outside the session manager, also import its file in `src/fuzz_targets.zig`. Pass the seeds and saved inputs to the test with `.corpus = &(@import("fuzz_seed").slices(.{ <seeds> }) ++ @import("fuzz_corpus").<target>.*)`. The session manager imports nothing from fx, so its targets keep their seeds as files in `tests/fuzz/corpus/<target>/` and pass `.corpus = &(.{""} ++ @import("build_options").fuzz_corpus_<target>.*)`. Set `iterations` so that one round of `--fuzz` takes about 30 seconds on a developer machine. `scripts/tests/test_fuzz_nightly.py` fails when an entry names a test that doesn't exist or that `zig build fuzz` can't reach. The MCP engine in `src/mcp/` imports only the standard library, so its targets live in `src/core/mcp_host/wire_tests.zig`. A file that holds only tests, like that one, is also imported from the test block in `src/main.zig`.

### Find data races

`-Dsanitize-thread=true` builds fx and its tests with ThreadSanitizer, which reports two threads touching the same memory without synchronization. The build is slow and large, so install it to its own prefix:

```bash
TSAN_OPTIONS=halt_on_error=0:abort_on_error=0 zig build test -Dsanitize-thread=true -p /tmp/fx-tsan
```

Without those options, the sanitizer aborts a test binary once it has reported a race, so that binary's later tests don't run. The Thread Sanitizer workflow runs the unit tests this way on `main` every night and lists each race in its job summary. It reports races without failing. A sanitized suite runs slower, so a few tests that depend on timing fail in it, such as the `command_runner` tests of output read after a command exits. Those failures aren't races.

### Check startup performance

The `Startup Latency` check fails a pull request when any benchmarked command takes longer than 2 ms on the Linux CI runner. To measure before you push, run:

```bash
./benchmarks/startup.sh --quick
```

The script builds a ReleaseSafe binary and needs hyperfine. On macOS, process and dynamic-loader overhead alone can exceed 2 ms, so compare local numbers between builds instead of against the budget. To measure an interactive launch up to its first frame, `benchmarks/first_frame.py` runs several binaries under the same machine load. In this example, `/tmp/fx-before` is a build of `main`:

```bash
python3 benchmarks/first_frame.py --binary /tmp/fx-before --binary ./zig-out/bin/fx
```

### Check a TLA+ model

`tests/tla/` holds TLA+ models of fx, such as the session manager, the MCP engine and host, ACP, `/usage`, the shell tool, the workspace indexer, and libfx. Most come with Bun drivers that run the real binary and have TLC check what it did. CI runs the libfx model; run the matching checker yourself when you change behavior that one of the others describes. You need Java and `tla2tools.jar`, and `tests/tla/README.md` lists every model and covers setup.

```bash
tests/tla/session_manager/check.sh SessionLog
tests/tla/mcp/check.sh --model Engine
bun test ./tests/tla/drivers/shell_command/
```

### Run the model evals

The evals in `tests/evals/` drive the agent through `fx ask --json` against real models and need `AI_GATEWAY_API_KEY`. They make billed model calls and their results vary between runs, so they aren't part of the pull request checks.

```bash
cd tests/evals
bun install
bun test
```

## Open a pull request

1. Sign every commit before you push it. `main` accepts only commits with verified signatures, and squash merging is turned off, so a single unsigned commit blocks the merge. GitHub explains how to set up [commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification) with an SSH or GPG key.
2. Push your branch. Maintainers push to `vercel-labs/fx`. Outside contributors push to their fork and open the pull request against `main`.
3. Open the pull request as a draft once your focused checks pass, so CI starts on it.
4. Write the title as a plain imperative sentence, such as `Restore feedback report file clipboard`. Leave out bracketed prefixes like `[bug]`, because the type goes in a label.
5. In the description, say what changes for users or callers, why it changes, and how you verified it, including what you ran with `./zig-out/bin/fx`.

### Choose a label

Every pull request needs exactly one `type:` label before it merges. Choose the label that matches the main reason the pull request exists:

| Label | Use it when the pull request |
| --- | --- |
| `type: bug` | Fixes incorrect behavior |
| `type: feature` | Adds a new user-facing capability |
| `type: improvement` | Improves existing user-facing behavior |
| `type: docs` | Changes documentation only |
| `type: maintenance` | Changes internal tooling, dependencies, CI, or code structure without changing user-facing behavior |
| `type: release` | Prepares or repairs a release |
| `type: security` | Fixes or hardens a security boundary |

Only maintainers can add labels. Maintainers add the label when they open the pull request and update it if the scope changes. When a pull request mixes kinds of change, the label follows its main purpose. Outside contributors leave the label off, and a maintainer adds it during review. A missing label never holds a pull request in draft.

## CI checks

CI runs on every push to a pull request, including drafts. Linux x86_64 gates every change, because most fx behavior is the same on every platform. A result counts only for the exact commit it ran on, so each new push needs a new passing run.

These five checks must pass before a pull request merges:

| Check | What it runs |
| --- | --- |
| `Build & Test` | Formatting, the PGSO corpus, the public-surface, compactor-boundary, and indexer-boundary checks, the ReleaseSafe unit tests, and the SDK package jobs |
| `E2E (deterministic)` | Every end-to-end file, split across four weighted shards, plus the MCP conformance baseline |
| `Shellcheck` | `bash -n` and `shellcheck` on the scripts listed in the job, such as `benchmarks/startup.sh` and `scripts/detect-macos-need.sh` |
| `Startup Latency` | The benchmarked CLI commands on a ReleaseSafe build, each held to 2 ms, plus the interactive performance test in `tests/e2e/tui-performance.test.ts` |
| `macOS arm64` | The macOS checks when the change needs them, and otherwise a pass without starting a macOS runner |

CI retries a failed end-to-end file once. A file that passes only on the retry gets a warning annotation, and you should investigate it as a possible race.

`scripts/detect-macos-need.sh` decides whether a change needs macOS. It runs the macOS checks when the change touches:

- A Zig file with a macOS, BSD, or Linux code path
- `build.zig`
- The macOS signing script
- The native SDK addon
- An end-to-end file listed in `tests/e2e/macos-platform-tests.json`
- A shared end-to-end helper that reads the platform

When the detector can't read the change, the `macOS arm64` check fails instead of passing.

Other workflows and benchmark jobs also report on pull requests, such as the `Examples` workflow when `examples/` changes and the `Shell command overhead` benchmark. Only the five checks above are required to merge, but look into any check that fails. Two of the others need more explanation:

- The binary size workflow builds each release target for the pull request and its base commit on native runners, reports the size change, and smoke-tests every target's binary. Growth of 52,429 bytes (0.05 MiB) or more on a platform adds a warning. Investigate growth you can't explain.
- The macOS arm64 PGSO workflow runs on a pull request only when the PGSO pipeline itself changes: `scripts/pgso/` other than `corpus.json`, the `setup-pgso` action, or `.github/workflows/pgso-macos-arm64.yml`. Stable releases always run it. [scripts/pgso/README.md](scripts/pgso/README.md) explains the pipeline and its acceptance gates.

Other runs start only on request:

| Run | Command |
| --- | --- |
| macOS checks | `gh workflow run macos.yml --ref your-branch`, or add the `ci:macos` label |
| PGSO qualification | `gh workflow run pgso-macos-arm64.yml --ref your-branch` |
| Live ACP suite | `gh workflow run ci.yml --ref your-branch -f acp_live=true` |
| Long-turn memory benchmark | `gh workflow run bench.yml --ref your-branch -f long_turn_memory=true` |
| libfx runtime benchmark | `gh workflow run bench.yml --ref your-branch -f libfx_runtime=true` |
| Fuzzing of one target | `gh workflow run fuzz.yml --ref your-branch -f target=<target>` |
| Unit tests with ThreadSanitizer | `gh workflow run tsan.yml --ref your-branch` |

Only maintainers can start these runs or add the `ci:macos` label. If you're an outside contributor and your change needs one of them, ask in the pull request and a maintainer will start it. If CI doesn't start at all on your first pull request, a maintainer may need to approve the workflow run.

## Mark it ready for review

Mark the pull request ready when all of these hold for its current commit:

1. All five required checks passed. A queued, cancelled, skipped, or failed run doesn't count, and neither does a run on an earlier commit.
2. You ran `./zig-out/bin/fx` through the changed behavior.
3. The diff against `main` contains only the files this change needs.
4. The documentation that describes the behavior is up to date.

If CI fails, push the smallest fix to the same pull request and wait for a passing run on the new commit.

## Update the docs

Update the documentation in the same pull request as the behavior it describes:

- The `--help` output comes from the command specs in `src/builtins/commands.zig`.
- `sdk/README.md` documents libfx. Update it when libfx's public behavior or setup changes, as [sdk/AGENTS.md](sdk/AGENTS.md) describes.
- Update this file when build steps, development setup, or collaboration rules change.

Change `README.md` only when one of its statements becomes false, or when a change adds a capability as broad as the ones in its feature list. A new option, command, or environment variable belongs in `--help` and the manual.

Don't edit `CHANGELOG.md` or the version in `src/main.zig`. Maintainers write the changelog when they prepare a release.

### Changes to the manual

The user manual at [fx.sh/docs](https://fx.sh/docs) is built from a private repository, so outside contributors can't edit it. When your change makes a manual page wrong or incomplete:

- Maintainers update the page in a companion pull request and link it from theirs.
- Outside contributors add a `## Docs` section to the pull request description with the exact change each affected page needs: the page URL, the section, and the text to add, replace, or remove. A maintainer makes the change in the manual.

For example:

```md
## Docs

- https://fx.sh/docs/configure-fx/permissions, "Change the mode": replace "<current text>" with "<new text>".
- https://fx.sh/docs/using-fx/sessions: add "<new paragraph>" after the first paragraph.
```

## Releases

Maintainers prepare each release in a pull request that bumps `pub const version` in `src/main.zig` and adds the new entry to `CHANGELOG.md`. When that pull request merges, the release workflow finds no tag for the new version, builds the binaries for every platform, creates the tag, and publishes the GitHub Release along with the binaries that the install script and `fx upgrade` download. Never create a version tag by hand. The [Releasing](AGENTS.md#releasing) section of AGENTS.md describes the changelog format and release markers.

To check release artifacts without publishing anything, run **Actions > Release** on `main` with `validate_only` enabled. The run builds every target, runs the PGSO qualification, and notarizes the macOS binaries. It creates no tag or GitHub Release, uploads nothing to the CDN, and changes no update channel.

After CI passes on `main`, the dev release workflow publishes binaries for that commit. Run `fx upgrade --channel dev` to follow those builds, and `fx upgrade --channel stable` to go back to tagged releases.

## License

fx is licensed under [Apache-2.0](LICENSE). Unless you state otherwise, a contribution you submit for inclusion in fx is licensed under the same terms, as section 5 of the license describes.
