<p align="center">
  <img src="art/di-roman-ii.png" width="240" alt="di Roman numeral II mark">
</p>

**di is the efficient agent for the terminal.** It is a coding agent CLI
written in Zig: one small native binary (Apache-2.0) with no runtime to
install. It spends few tokens per task because tool output is capped and
searches stay narrow, and it stays light on CPU and RAM because the agent is a
single native process with no daemon and no background index. It is
model-agnostic, embeds as a harness in larger systems, and its interface stays
closer to a Unix shell than an IDE in the terminal.

## Highlights

- **Efficient by default:** tool output is capped, parallel tool batches stay bounded, and the whole agent is one native process, so token spend and CPU/RAM use stay predictable
- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter, including [OpenPaths](https://openpaths.io)
- **Any interface:** interactive shell, one-shot `di ask` for scripts, or embedded through libfx and ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Inline images:** PNG screenshots and attachments render in the transcript through Kitty graphics, with a text fallback in other terminals
- **Live status:** session cost, token totals, context usage, and the current Git branch stay visible in the status line
- **Extensible:** skills, MCP servers, and subagents
- **Project instructions:** honors AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules, and .github/copilot-instructions.md at the workspace root and in scoped directories
- **Grounded web research:** `gemini_search` answers queries through Gemini grounded by Google Search (set `GEMINI_API_KEY`)

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/lee101/di/releases/latest"><img alt="di CLI release" src="https://img.shields.io/github/v/release/lee101/di.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/lee101/di/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/lee101/di.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Build

Requires Zig 0.16 or newer. If `zig version` prints 0.15.x, build with `~/.zvm/bin/zig build` or make Zig 0.16 the default on `PATH`.

```bash
git clone https://github.com/lee101/di.git
cd di
zig build -Doptimize=ReleaseSafe
./zig-out/bin/di
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Get started

di detects available credentials at startup. With `OPENPATHS_API_KEY` or
`OPENROUTER_API_KEY` in the environment, it selects that compatible transport
and works immediately without a setup command:

```bash
export OPENPATHS_API_KEY=...   # or OPENROUTER_API_KEY
di
```

The default model is `xiaomi/mimo-v2.6-pro` for an OpenPaths key and
`stealth/space-bunny-alpha` for an OpenRouter key. Model lists are fetched
live from OpenPaths or OpenRouter and cached on disk, so new models such as
`xiaomi/mimo-v2.6-flash` show up in `/model` without an update; when a listing
is unavailable, any model id can be typed directly. OpenRouter may retire a
stealth model without notice, so both stealth routes circuit-break to
`xiaomi/mimo-v2.6-pro` for the rest of the turn and show a recovered banner.

OpenRouter `:free` variants and the `openrouter/free` router still require an
`OPENROUTER_API_KEY`; “free” describes inference price, not anonymous API
access. Likewise, a ChatGPT/Codex subscription authorizes only the models in
its authenticated Codex catalog. To select a DeepSeek or other third-party
row, provide an OpenPaths, OpenRouter, or AI Gateway credential that advertises
that model. di switches the route automatically when the model is selected—it
does not copy one provider's bearer token to another provider.

`/model` is a unified searchable catalog. It merges models available through
OpenPaths, OpenRouter, Vercel AI Gateway, an eligible ChatGPT/Codex
subscription, and an eligible Grok subscription. Selecting a row also selects
the credential and transport that advertised it, so model choice is the normal
workflow rather than a separate provider-configuration exercise. The latest
catalog is cached under `~/.fx` so the menu opens instantly and refreshes in the
background, and a typed id that is not listed still selects through the
`Use <query>` row.

Only language models are listed. OpenPaths serves embeddings, speech
transcription and synthesis, music, image, video, and 3D models from the same
catalog, and those answer a different endpoint, so a row for one is a
selection that cannot work once it is made. Providers that publish a model
type are taken at their word; for the rest the same pricing and id signals
OpenPaths itself classifies on decide. A model you know is served but is not
listed can still be typed directly through the `Use <query>` row.

Sign in with one of:

- `di login`: Vercel AI Gateway
- `di login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `di login grok`: Grok subscription (xAI OAuth)
- `di setup`: AI Gateway API key

An existing Codex CLI login at `$CODEX_HOME/auth.json` (default
`~/.codex/auth.json`) is adopted on first use, so a ChatGPT plan already signed
in there needs no `di login codex`. di copies the session into its own `~/.fx`
profile and refreshes it there; the CLI's file is never modified.

di loads Grok models from your subscription's live catalog, so new supported models appear without a static model list. Public xAI metadata enriches image support but does not filter subscription models.

Then start the interactive shell from a project:

```bash
cd your_project
di
```

Or make a one-shot request:

```bash
di ask "explain the changes in this repository"
```

The status line keeps session spend honest: cumulative cost, token totals,
context usage against the model window, and the current Git branch, backed by
the same accounting as `/cost` and `/usage`. PNG images in the transcript
render inline through Kitty graphics (kitty, Ghostty, WezTerm, Warp), and fall
back to a stable `[Image: ...]` line elsewhere (force with `FX_KITTY_IMAGES=1`,
suppress with `FX_NO_KITTY_IMAGES=1`).

### Compatibility state

This first rebranded release intentionally reads the existing `~/.fx` profile
and `FX_*` environment variables. That preserves prior sessions, skills, and
ChatGPT/Codex login state for people moving from fx. New provider keys use
their standard names: `OPENPATHS_API_KEY`, `OPENROUTER_API_KEY`, and
`AI_GATEWAY_API_KEY`.

A few fx names stay because they are identities the CLI does not own. The
documentation lives at `fx.sh`, the npm package is `libfx` with `fx-*`
artifacts, the built-in themes are `fx-dark` and `fx-light`, and the Slack
workspace app is registered as fx with its callback at `fx.sh`.

## Efficiency

Token spend and machine cost are design constraints here, not numbers measured
after the fact. Each lever below is visible in the CLI, and each one is yours to
change.

### Tokens

- **Tool output is capped.** Every tool result stops at 64 KiB by default, so a
  single verbose search cannot fill the context window. Change the ceiling with
  `max_tool_result_bytes` in `~/.fx/settings.json` or a project `.fx.json`.
- **Searches stay on the cheap path.** In full-access mode a clean recursive
  grep runs through ripgrep, and `fuzzy_search` reads an existing local index.
  Neither spends an extra model round trip.
- **Independent work batches instead of serializing.** Parallel tool groups run
  at most eight calls at a time and preserve result order, so eight reads cost
  one turn instead of eight.
- **Polling is discouraged.** The agent is guided to narrow search roots, batch
  independent reads, and wait on a running shell session instead of re-reading
  its output. See [Efficient local searches](#efficient-local-searches) for the
  search paths in detail.

`/usage` reports recorded token usage and spend for a period, and the status
line keeps cumulative cost, token totals, and context usage against the model
window visible while you work.

### CPU and RAM

- **One native process.** di is a single Zig binary whose only shared library
  dependency is libc. There is no Node, no Python, and no daemon to supervise.
- **Bounded fan-out.** Tool groups, command output, and local index reads all
  have explicit ceilings, so a wide parallel group cannot become unbounded work.
- **Local search without a GPU.** `fuzzy_search` runs the backend in-process
  with a 15-second deadline and a 64 KiB output cap, reads an index of up to
  64 MiB, and never creates or refreshes one.
- **Rendering stays inline.** The transcript renders into the main grid, which
  is what preserves your scrollback. Only permission review, the full transcript
  on Ctrl+O, and catalog menus take the alternate screen, so ordinary repaints
  and resizes stay cheap.
- **Startup is budgeted.** Linux CI holds every CLI path to a 2 ms startup
  budget, and `di help` is the baseline that measures it.

## Efficient local searches

The agent can choose among these search tools:

| Tool | Use |
| --- | --- |
| `fuzzy_search` | Semantic discovery of local code using an existing zbed index. |
| `grep_files` | Exact literal matches with bounded output and context. |
| `shell` with `rg` | Regex search, filename search, or command-line search when preferred. |
| `gemini_search` | Public web research with a grounded answer and citations; requires `GEMINI_API_KEY`. |
| `web_search` | Public web search results through the configured search provider. |

To enable `fuzzy_search`, build the zbed checkout with Zig 0.16.0,
then configure trusted absolute paths before launching di:

```bash
export FX_ZBED_BIN=/path/to/zbed/zig-out/bin/zbed
export FX_ZBED_MODEL_DIR=/path/to/zbed/model
"$FX_ZBED_BIN" index /path/to/project --model-dir "$FX_ZBED_MODEL_DIR"
```

Index a suitably narrow directory explicitly. `fuzzy_search` takes `query`,
optional workspace-relative `path`, and `limit` (1–50, default 10). It requires
the updated backend advertising `zbed-search-readonly-v1`, reads an existing
index up to 64 MiB, and never creates or refreshes an index. Searches are local,
use no GPU or daemon, have a 15-second execution deadline and a 64 KiB output
cap. Results may be stale; verify them against current files. A missing backend
or index leaves `rg` and `grep_files` available. Existing `grep` permission rules
also govern `fuzzy_search`, which is restricted to the workspace.

Use `grep_files` for literal search, `glob_files` for discovery, and `rg` for
shell searches. The agent is guided to narrow search roots, batch independent
reads, and wait on existing shell sessions instead of repeatedly polling.
Parallel tool groups run in batches of at most eight, preserving result order
and keeping mutations behind preceding reads.

In full-access mode, captured `shell` calls with `profile: "clean"` automatically
translate a conservative subset of recursive text searches to ripgrep. For
example, `grep -ranFH needle src` uses `rg` when available, with the original
command as the fallback when it is absent. Hidden and ignored files remain in
scope; ripgrep config is disabled and the search uses one worker. The executed
command is recorded in the shell result.

Translation requires explicit text mode (`-a`), recursion (`-r` or `-R`) and
filename formatting (`-H` or `-h`). It accepts fixed strings (`-F`) or simple
literal patterns, plus line numbers (`-n`). Other flags, binary detection,
regexes, expansions, pipelines, interactive shells, user startup profiles, and
exact-command approval modes retain their original command. No extra model
round trip is required. See [the op comparison](docs/op-parity.md) for coverage
and remaining gaps.

## di infinity

di infinity is the infinite run harness: one `di ask` invocation that keeps working across turns until you interrupt it. After every completed turn, the saved session receives a generated follow-up prompt built from the latest work summary, so progress compounds instead of stopping at the first answer.

```bash
# keep executing the next logical implementation steps, forever
di ask --auto-next-steps --yolo "fix the failing tests and improve the implementation"

# finish the current plan, then brainstorm and ship improvements, forever
di ask --auto-next-idea --yolo "polish the terminal renderer"

# both: alternate between next steps and next ideas until interrupted
di ask --auto-next-steps --auto-next-idea --yolo "harden the gateway client"
```

How the cycle runs:

- `--auto-next-steps`: after each turn, breaks the overall goal into concrete next steps and executes them in order, running relevant tests along the way.
- `--auto-next-idea`: after the current plan is done, shifts into ideation mode, brainstorms at least three concrete improvements, picks the highest-impact one, and starts executing immediately.
- Together they form an unbounded loop; every third single-flag turn also re-reviews recent work against the original objective before acting.
- Failed turns retry automatically with exponential backoff (1s doubling to 16s), resuming the same saved session. Non-retryable failures exit nonzero.
- Stop anytime with Ctrl+C. Sessions are always saved, so `di ask --resume last` picks the harness back up later.

Autonomous mode requires session saving and cannot be combined with `--no-save`. Pair it with `--json` to get one parseable result object per turn on stdout.

## di improves di

di can act as a subagent on its own repository. Every iteration starts from a
clean tree, runs one autonomous `di ask` turn, then gates the result with a
ReleaseSafe build and the full test suite before committing and pushing.

```bash
export OPENPATHS_API_KEY=...
scripts/self-improve.sh                          # one pass, default model muse-spark-1.3-contributor
scripts/self-improve.sh -n 5 --valgrind          # five passes, valgrind gate too
scripts/self-improve.sh -m deepseek/deepseek-v4-flash-vision-exp -- "make /model list every catalog"
scripts/self-improve.sh --merge-upstream         # merge vercel-labs/fx main; di resolves conflicts
```

Iterations that fail to build or introduce a new failing test are reverted, so
the branch only ever gains passing commits. The test gate compares against a
baseline captured from the clean tree, so pre-existing failures on a machine do
not block progress. `--no-push` keeps commits local; `--remote` and
`--upstream` select the git remotes.

## Valgrind

```bash
scripts/valgrind.sh                       # offline CLI surface under memcheck
scripts/valgrind.sh --ask "say hi"        # plus one live ask turn
scripts/valgrind.sh --tests model_fallback   # unit tests matching a filter under memcheck
```

The script builds a Debug binary with symbols, reports the memcheck error
summary per command, and exits nonzero on definite leaks or invalid accesses.
`zig build test -Dtest-filter=NAME` runs a subset of tests without valgrind.

di starts in full-access permission mode. Tool lookup, argument validation, cancellation, limits, operating-system permissions, and remote authentication stay authoritative, and no approval screen or automatic safety review gates an action. Switch to `auto` for the bounded safety review of unresolved sensitive actions, or to `ask` to require approval before changes. Ordinary question text never grants permission. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for the other modes and persistent rules.

Questions follow the same dial. The question tool is advertised only in `ask` mode, where it opens the real question screen. In `auto` and full access no question screen opens and the tool is not advertised: the agent answers its own question with the most conservative option that still completes the task, states the assumption and its basis, and keeps going instead of stopping the turn.

Inside the shell, run `/help` to browse interactive commands.

In tmux, use your usual prefix bindings to switch sessions or enter copy mode.
di preserves those tmux views while resizing, including when the switcher zooms a split pane.

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
di provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 di ask "review this change"
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Ultrafast mode

Ultrafast mode is off by default. It requests OpenAI's higher-cost Gateway service tier with `openai.serviceTier: "ultrafast"` for models whose Gateway metadata advertises Ultra eligibility. `ultrafast_requested` in `di status --json` and `/status` reports the request, not a guarantee that a provider served the tier.

Set a profile default in `~/.fx/settings.json`:

```jsonc
{
  "provider": "gateway",
  "models": { "gateway": "openai/gpt-6-astra" },
  "ultrafast_mode": true
}
```

Use it explicitly in an interactive session, a one-shot request, or ACP:

```bash
di --ultrafast
di ask --ultrafast "review this change"
di acp --ultrafast
```

Use `/ultrafast on`, `/ultrafast off`, or `/ultrafast status` in the shell. The Settings menu includes an Ultra mode row. `FX_ULTRAFAST=1` and `--ultrafast` are process-local opt-ins and are not persisted. `FX_ULTRAFAST=0`, `--no-ultrafast`, and `/ultrafast off` explicitly disable it. A resumed session keeps its saved request unless a higher-precedence explicit disable applies.

Ultra mode is available only through the Vercel AI Gateway's OpenAI service tier. Gateway metadata currently marks Astra eligible. di does not select Ultra automatically, and switching models clears an existing Ultra request. Subagents inherit the parent turn's request; an explicit parent disable and capability checks override an existing child preference. Background side calls, including titles, reviews, and compaction, do not use Ultra mode.

## Gateway provider routing

When the active model goes through the Vercel AI Gateway, one model is often served by several providers (for example Anthropic directly, AWS Bedrock, or Google Vertex). di can tell the gateway which providers to use, in what order:

```jsonc
// ~/.fx/settings.json
{
  "provider_order": ["bedrock", "anthropic"], // try Bedrock first, then Anthropic
  "provider_strict": false                     // true restricts requests to only these providers
}
```

Both keys also work in a committed project `.fx.json`, and per launch:

```bash
di --provider-order azure,openai --provider-strict
di ask --provider-order bedrock "review this change"
FX_PROVIDER_ORDER=vertex FX_PROVIDER_STRICT=1 di
```

Slugs are the gateway's provider identifiers (letters, digits, dashes, for example `anthropic`, `bedrock`, `vertexAnthropic`), listed on the [models page](https://vercel.com/ai-gateway/models). An empty `provider_order` in a higher-precedence layer clears a list set by a lower one. Routing applies to gateway requests only; custom model connections ignore it.

## Themes

di ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Context compaction

When a conversation fills the model's context, di compacts it so the work can continue. The newest few turns stay unchanged. Every compacted turn keeps your messages and the assistant's final reply word for word. The conversation's own model adds a short note on what the assistant did in between, and a line for each tool call: di writes what the call was from the call itself, like `shell zig build test (failed, exit 1, 3120 bytes)`, and the model adds why it was used and what it showed. The model also keeps numbered entries for your rules, quoted word for word, and for facts, decisions, status and open questions, plus a list of the skills and MCP tools used. Entries are never rewritten: a later entry can say it replaces an earlier one. At the next compaction, the one before it is saved whole with an ID like `L2`, and in its place the agent sees a short summary the model writes of all earlier compactions, plus their rules, status and open entries still in force, word for word. The turns of earlier compactions leave the agent's view however many compactions a session has; only those kept entries grow with it. In a session that is not saved, nothing can be stored, so earlier compactions stay in view. di checks every new note and entry, and marks without removing one that names no source, quotes words you did not write, states a path, number, version or quoted text found in none of the compacted turns and tool calls, names an ID that does not exist, or calls a failed tool call a success; turns the model skipped, or a missing summary of earlier compactions, are asked for once more. Only when the compacted conversation would leave too little room to continue are its longest texts shortened to their start and end, each naming the saved turn that keeps it whole. Every compacted turn is saved word for word with an ID like `M3`, every tool call with its input and output as the model saw them, plus the handle of any full output saved separately, with an ID like `T12`, and every earlier compaction with an ID like `L2`. The agent can search them by text or open one by ID with `read_tool_result`; a search also says how many saved records hold all of its words, and which came first and last.

Automatic compaction asks the model right after the conversation, exactly as the agent was about to send it and with the same settings, so the provider can reuse what it has cached. When that request does not fit or fails, and when you run `/compact` to compact now, di writes the turns out in a separate request at the model's lowest reasoning; turns too large for one such request go oldest first, in as many requests as it takes. If a separate request fails or comes back empty on AI Gateway, di retries it once with a model from another provider.

Automatic compaction starts when a request reaches 80 percent of the model's usable input. Set `auto_compact_percent` in `~/.fx/settings.json` to any value from 10 to 80, or `FX_AUTO_COMPACT_PERCENT` for a single launch:

```jsonc
// ~/.fx/settings.json
{ "auto_compact_percent": 60 }
```

## Embed di

di builds as a native binary or WebAssembly. Applications embedding di can provide network transport, session storage, configuration, permission handling, and terminal I/O. The experimental JavaScript SDK keeps its existing `fx-*` artifact names for upstream compatibility.

| Surface | Use |
| --- | --- |
| `di acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

ACP clients can keep their MCP tools loaded on every turn, steer a running turn, supply a session system prompt, serve MCP servers over the ACP connection, and choose each session's workspace. See [ACP embedding](CONTRIBUTING.md#acp-embedding).

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Connect your Slack account

Run `/mcp add slack` in a di session, or `di mcp add slack` from your terminal.
The command saves Slack's MCP URL and the public fx Client ID to your profile,
opens the fx.sh authorization flow, and connects Slack after you consent. Keep
di running while you authorize in a browser on the same computer. In a di
session, Slack's tools become available without a restart. The **Servers** tab
in `/mcp` also offers **Add Slack** with the `s` key.

You don't need to edit `~/.fx/mcp.json` or run `di slack install` to connect your
personal account. Workspace app approval may still be required. di reports
`Slack connected. You can now use Slack.` after the connection succeeds.

Running the command again uses an existing working connection or starts
missing authorization. It restores a missing fx Client ID and preserves other
servers, timeouts, and explicit scope overrides. A conflicting Slack endpoint,
Client ID, or authentication configuration stops setup with guidance instead of
being overwritten. Use `/mcp auth slack --open` to reauthorize an existing
configuration. Removing and re-adding the di preset restores its configuration;
it does not revoke credentials. Use `/mcp logout slack` to sign out.

## Slack workspace installation

Run `di slack install` to install the fx Slack app in the configured Vercel Slack
workspace. Keep the command running and authorize Slack in a browser on the same
computer. The HTTPS callback at fx.sh returns the authorization to the CLI;
PKCE state and the verifier stay in memory. The companion web bridge must be
deployed and configured first.

After the CLI saves the installation, the browser returns to an fx.sh confirmation
page. You can close that tab or refresh it after the command exits.

`di slack status --json` reports local installation metadata without tokens.
Plain-text output omits Slack IDs and shows expiration as a readable UTC date
and time. JSON output retains the IDs and Unix timestamps for scripts.
`di slack refresh` rotates the local bot credentials when needed. Credentials
live in the owner-only file `~/.fx/slack/installation.json`; no hosted database
or background refresh service is created. An expired refresh token requires
installation again. This workspace operation is separate from each employee's
MCP user authorization. Employees connect their own account with
`/mcp add slack` in a di session (or `di mcp add slack` from a terminal).
For `https://mcp.slack.com/mcp`, the CLI recognizes the fx app by its public
Client ID and uses the HTTPS callback for personal login. Changing that Client
ID requires a CLI update. OAuth uses the canonical form of Slack's advertised
resource, `https://mcp.slack.com/`, while the MCP transport remains at
`https://mcp.slack.com/mcp`. First login and reauthorization request the full shared
`user_scopes` list from fx.sh. If local `scopes` are configured, they must include
every shared scope; extra local scopes are not requested. A narrower or explicitly
empty list stops authorization before opening the browser, leaving the configuration
and stored credentials unchanged. Remove the override only if you want to authorize
the full shared scope set. Per-user read-only subsets are not supported for the fx app. Saved scopes,
Slack's advertised capabilities, and scope challenges cannot expand this
request. The shared list contains nine personal scopes configured for fx and
advertised by Slack MCP; changing it requires a deliberate configuration update
and any necessary Slack approval. This does not revoke
permissions on previously issued tokens or change token refresh behavior. It
opens an ephemeral loopback listener instead of the configured `callback_port`,
keeps PKCE and personal tokens in the CLI, and shows “Slack connected” after
saving to the existing MCP credential store. Other MCP providers and different
Slack app Client IDs retain their direct callback behavior without contacting
fx.sh. Fx app authorization requires fx.sh to be available; an unavailable
metadata endpoint returns `SlackBridgeUnavailable`. Deploy the web
personal-authorization routes and scope metadata before releasing this CLI.
Missing or invalid shared scopes stop authorization rather than falling back
to Slack's broader capabilities. Keep the registered
localhost callback for older clients until they have upgraded. Slack workspace
approval requirements still apply to personal authorization.

Bot installation does not establish whether
Slack will display a hoverable “Sent using @fx” attribution; that requires a
live message test.

## Security

Report security vulnerabilities through the [contact page](https://fx.sh/contact) instead of a public issue.

On Linux, di marks itself non-dumpable (`PR_SET_DUMPABLE=0`) and sets `RLIMIT_CORE` to 0 at startup, so same-user processes cannot ptrace it or read its memory, and crashes do not write core files. Child processes inherit the zero core limit. Set `FX_ALLOW_DEBUG=1` to skip this hardening when attaching gdb or running under valgrind.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
