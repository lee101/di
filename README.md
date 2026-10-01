<p align="center">
  <img src="art/di-roman-ii.png" width="240" alt="di Roman numeral II mark">
</p>

di is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter [OpenPaths](https://openpaths.io)
- **Any interface:** interactive shell, one-shot `fx ask` for scripts, or embedded through libfx and ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Inline images:** PNG screenshots and attachments render in the transcript through Kitty graphics, with a text fallback in other terminals
- **Live status:** session cost, token totals, context usage, and the current Git branch stay visible in the status line
- **Extensible:** skills, MCP servers, and subagents
- **Project instructions:** honors AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules, and .github/copilot-instructions.md at the workspace root and in scoped directories
- **Grounded web research:** `gemini_search` answers queries through Gemini grounded by Google Search (set `GEMINI_API_KEY`)

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/releases/latest"><img alt="fx CLI release" src="https://img.shields.io/github/v/release/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Build

Requires Zig 0.16 or newer. If `zig version` prints 0.15.x, build with `~/.zvm/bin/zig build` or make Zig 0.16 the default on `PATH`.

```bash
git clone https://github.com/lee101/di.git
cd di
zig build -Doptimize=ReleaseSafe
./zig-out/bin/di
```

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
in there needs no `fx login codex`. di copies the session into its own `~/.fx`
profile and refreshes it there; the CLI's file is never modified.

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
fx preserves those tmux views while resizing, including when the switcher zooms a split pane.

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
fx provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Gateway provider routing

When the active model goes through the Vercel AI Gateway, one model is often served by several providers (for example Anthropic directly, AWS Bedrock, or Google Vertex). fx can tell the gateway which providers to use, in what order:

```jsonc
// ~/.fx/settings.json
{
  "provider_order": ["bedrock", "anthropic"], // try Bedrock first, then Anthropic
  "provider_strict": false                     // true restricts requests to only these providers
}
```

Both keys also work in a committed project `.fx.json`, and per launch:

```bash
fx --provider-order azure,openai --provider-strict
fx ask --provider-order bedrock "review this change"
FX_PROVIDER_ORDER=vertex FX_PROVIDER_STRICT=1 fx
```

Slugs are the gateway's provider identifiers (letters, digits, dashes, for example `anthropic`, `bedrock`, `vertexAnthropic`), listed on the [models page](https://vercel.com/ai-gateway/models). An empty `provider_order` in a higher-precedence layer clears a list set by a lower one. Routing applies to gateway requests only; custom model connections ignore it.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Embed di

di builds as a native binary or WebAssembly. Applications embedding di can provide network transport, session storage, configuration, permission handling, and terminal I/O. The experimental JavaScript SDK keeps its existing `fx-*` artifact names for upstream compatibility.

| Surface | Use |
| --- | --- |
| `di acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

ACP clients can keep their MCP tools loaded on every turn, steer a running turn, supply a session system prompt, serve MCP servers over the ACP connection, and choose each session's workspace. See [ACP embedding](CONTRIBUTING.md#acp-embedding).

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Slack workspace installation

Run `fx slack install` to install the fx bot in the configured Vercel Slack
workspace. Keep the command running and authorize Slack in a browser on the same
computer. The HTTPS callback at fx.sh returns the authorization to the CLI;
PKCE state and the verifier stay in memory. The companion web bridge must be
deployed and configured first.

After the CLI saves the installation, the browser returns to an fx.sh confirmation
page. You can close that tab or refresh it after the command exits.

`fx slack status --json` reports local installation metadata without tokens.
Plain-text output omits Slack IDs and shows expiration as a readable UTC date
and time. JSON output retains the IDs and Unix timestamps for scripts.
`fx slack refresh` rotates the local bot credentials when needed. Credentials
live in the owner-only file `~/.fx/slack/installation.json`; no hosted database
or background refresh service is created. An expired refresh token requires
installation again. This workspace operation is separate from each employee's
MCP user authorization. Employees connect their own account with
`/mcp auth slack --open` in an fx session (or `fx mcp auth slack` from a terminal).
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

## Build from source

Building di requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/lee101/di.git
cd di
zig build -Doptimize=ReleaseSafe
./zig-out/bin/di
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Security

Report security vulnerabilities through the [contact page](https://fx.sh/contact) instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
