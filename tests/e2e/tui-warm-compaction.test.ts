import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

process.env.FX_E2E_DISABLE_DOTENV = "1";
const {
  FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayToolCall, fakeGatewaySse,
  heldFakeGatewayFinalText, startDynamicFakeGateway, hasEmptyComposer, tmuxAvailable,
} = await import("./tmux-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const HEAD = "WARM_HISTORY_HEAD_5a1e";
const TURN_REPLY = "WARM_TURN_REPLY_c93d";
const FIRST_END = "WARM_FIRST_TURN_END_3c7a";
const NEXT_REPLY = "WARM_NEXT_REPLY_20bf";
const NOTE = "In between: Read the notes file.";
const FACT = "Facts:\nF1: WARM_HANDOFF_91c4 keep the history head.";
const HANDOFF = `Turn 1\n${NOTE}\n\nTurn 2\n${NOTE}\n\nTurn 3\n${NOTE}\n\n${FACT}`;
const FRESH_HANDOFF = `Turn 1\n${NOTE}\n\n${FACT}`;
const INSTRUCTION_MARKER = "You write compaction notes";
const REPORTED_INPUT_TOKENS = 80_000;

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function finalText(text: string, inputTokens: number) {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: { inputTokens: { total: inputTokens }, outputTokens: { total: 5 } },
    },
  ]);
}

async function until(predicate: () => boolean, label: string, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await Bun.sleep(20);
  }
}

function texts(message: { content: unknown }): string {
  const content = message.content;
  if (typeof content === "string") return content;
  return (content as { text?: string }[]).map((part) => part.text ?? "").join("");
}

type Prompt = { role: string; content: unknown }[];

async function fixture(fresh: boolean, env_extra: Record<string, string> = {}) {
  const root = mkdtempSync(join(tmpdir(), "fx-warm-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace);
  writeFileSync(join(workspace, "seed-notes.txt"), "seed notes\n");
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    model: FAKE_GATEWAY_MODEL, auto_upgrade: false, startup_scrollback: false,
  }), { mode: 0o600 });
  const summaryHold = heldFakeGatewayFinalText();
  let phase: "seed" | "turn" | "next" = fresh ? "turn" : "seed";
  let freshTurns = 0;
  let hold = false;
  let ordinary = 0;
  const summaries: Prompt[] = [];
  const ordinaryPrompts: { prompt: Prompt; tools: unknown; toolChoice: unknown; bytes: number; at: number }[] = [];
  let terminal: InstanceType<typeof TmuxSession> | undefined;
  const seedReply = (turn: number) => `${turn === 1 ? HEAD : `WARM_HISTORY_MIDDLE_${turn}`}\n${"history alpha beta gamma delta sample line\n".repeat(1600)}SEED_DONE_${turn}`;
  const gateway = startDynamicFakeGateway((raw) => {
    const request = JSON.parse(raw);
    const prompt: Prompt = request.prompt ?? [];
    const last = prompt.at(-1);
    if (last && last.role === "user" && texts(last).includes(INSTRUCTION_MARKER)) {
      summaries.push(prompt);
      return hold ? summaryHold.response : finalText(fresh ? FRESH_HANDOFF : HANDOFF, 100);
    }
    if (request.toolChoice?.type === "none" && request.tools?.length === 0) {
      summaries.push(prompt);
      return finalText(fresh ? FRESH_HANDOFF : HANDOFF, 100);
    }
    const seedRead = `seed-read-${ordinary + 1}`;
    if ((phase === "seed" || (fresh && phase === "turn" && freshTurns === 0)) && !raw.includes(`"${seedRead}"`)) return fakeGatewayToolCall(seedRead, "read_file", { path: "seed-notes.txt" });
    ordinary++;
    ordinaryPrompts.push({ prompt, tools: request.tools, toolChoice: request.toolChoice, bytes: raw.length, at: Date.now() });
    if (phase === "seed") return finalText(seedReply(ordinary), 1000);
    if (fresh && phase === "turn" && freshTurns === 0) {
      freshTurns++;
      return finalText(HEAD + "\n" + "first turn filler line\n".repeat(600) + FIRST_END, 1000);
    }
    return finalText(phase === "turn" ? TURN_REPLY : NEXT_REPLY, phase === "turn" ? REPORTED_INPUT_TOKENS : 1000);
  }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-warm-key",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_SKIP_ONBOARDING: "1",
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    ...env_extra,
  };
  let sessionId = "";
  const stderrPaths: string[] = [];
  const traceLog = join(root, "terminal.trace");
  async function cli(args: string[]) {
    const child = Bun.spawn([binary, ...args], { cwd: workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill(), 30_000);
    try {
      const [code, stdout] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      expect(code).toBe(0);
      return JSON.parse(stdout);
    } finally { clearTimeout(timer); }
  }
  const events = () => readFileSync(join(home, ".fx/sessions", sessionId, "events.jsonl"), "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  const checkpoints = () => events().filter((row) => row.event?.context_checkpoint).length;
  async function seed() {
    for (let turn = 1; turn <= 3; turn++) {
      const reply = await cli(["ask", "--json", "--auto", ...(sessionId ? ["--resume", sessionId] : []), `Seed ordinary historical turn ${turn}.`]);
      if (sessionId) expect(reply.session_id).toBe(sessionId);
      else sessionId = reply.session_id;
      expect(ordinary).toBe(turn);
    }
    expect(summaries).toHaveLength(0);
    expect(checkpoints()).toBe(0);
    phase = "turn";
  }
  function adoptSession() {
    sessionId = readdirSync(join(home, ".fx/sessions")).find((name) => !name.startsWith("."))!;
    expect(sessionId).toBeTruthy();
  }
  async function launch() {
    const stderr = join(root, "terminal.stderr");
    stderrPaths.push(stderr);
    const terminalEnv = { ...env, FX_TRACE_LOG: traceLog, FX_TRACE_SCOPES: "context_compaction,compaction,worker,agent" };
    const command = `/usr/bin/env -i ${Object.entries(terminalEnv).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)}${fresh ? "" : ` --resume ${shellQuote(sessionId)}`}`;
    terminal = await TmuxSession.create({
      cmd: command, cwd: workspace, env: { HOME: home, FX_SOUND: "0" }, isolated: true,
      stderrPath: stderr, width: 90, height: 32, minimumHistoryLines: 5_000, startupWaitMs: 0,
    });
    await terminal.waitForStableComposer(20_000);
    await terminal.sendLiteral("startup-input-handshake");
    await terminal.waitForText("startup-input-handshake", 5000);
    await terminal.sendKeys("C-u");
    await terminal.waitForComposer(5000);
    return terminal;
  }
  async function close() {
    if (!terminal) return;
    await terminal.sendText("/quit");
    expect(await terminal.waitForSessionEnd(5000)).toBe(true);
    await terminal.kill();
    terminal = undefined;
    for (const path of stderrPaths) expect(readFileSync(path, "utf8")).toBe("");
  }
  async function cleanup(passed: boolean) {
    if (!passed) {
      writeFileSync(join(root, "requests.json"), JSON.stringify({ phase, ordinary, summaries: summaries.length, ordinaryPrompts: ordinaryPrompts.map((p) => ({ n: p.prompt.length, bytes: p.bytes })) }, null, 2));
      console.error(`warm compaction evidence retained: ${root}`);
    }
    summaryHold.dispose();
    await terminal?.kill();
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
  }
  return {
    seed, launch, close, adoptSession, cleanup, checkpoints, root, traceLog, summaries, ordinaryPrompts,
    ordinary: () => ordinary,
    phase: (value: typeof phase) => { phase = value; },
    hold: (value: boolean) => { hold = value; },
    release: (text: string) => summaryHold.release(text),
    requestsContaining: (marker: string) => gateway.requests.map((request) => request.body).filter((body) => body.includes(marker)),
  };
}

describe.skipIf(!tmuxAvailable())("tui: warm post-turn compaction", () => {
  test("compacts right after a large turn with the conversation prefix and the next turn starts from the checkpoint", async () => {
    const f = await fixture(false);
    let passed = false;
    try {
      await f.seed();
      const terminal = await f.launch();
      await terminal.sendText("Continue the current turn.");
      await terminal.waitForPane((pane) => pane.includes(TURN_REPLY) && hasEmptyComposer(pane), 20_000);
      await until(() => f.summaries.length >= 1, "warm summary request after the turn");
      const turn = f.ordinaryPrompts.at(-1)!;
      const summary = f.summaries[0]!;
      expect(summary.length).toBe(turn.prompt.length + 2);
      for (let index = 0; index < turn.prompt.length; index++) {
        expect(summary[index]!.role).toBe(turn.prompt[index]!.role);
        expect(texts(summary[index]!)).toBe(texts(turn.prompt[index]!));
      }
      expect(summary[turn.prompt.length]!.role).toBe("assistant");
      expect(texts(summary[turn.prompt.length]!)).toContain(TURN_REPLY);
      expect(texts(summary.at(-1)!)).toContain(INSTRUCTION_MARKER);
      await until(() => f.checkpoints() === 1, "warm checkpoint committed");
      f.phase("next");
      const before = f.summaries.length;
      await terminal.waitForPane((pane) => hasEmptyComposer(pane), 10_000);
      await terminal.sendText("Follow the compacted context.");
      await terminal.waitForPane((pane) => pane.includes(NEXT_REPLY) && hasEmptyComposer(pane), 20_000);
      const next = f.ordinaryPrompts.at(-1)!;
      expect(JSON.stringify(next.prompt)).toContain("<compacted_conversation>");
      expect(JSON.stringify(next.prompt)).toContain("WARM_HANDOFF_91c4");
      expect(next.bytes).toBeLessThan(turn.bytes * 0.75);
      expect(f.summaries.length).toBe(before);
      expect(f.checkpoints()).toBe(1);
      const trace = readFileSync(f.traceLog, "utf8");
      expect(trace).toContain("warm_decision");
      expect(trace).toContain("warm_committed");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 120_000);

  test("FX_AUTO_COMPACT_WARM_PERCENT=0 leaves the finished turn alone", async () => {
    const f = await fixture(false, { FX_AUTO_COMPACT_WARM_PERCENT: "0" });
    let passed = false;
    try {
      await f.seed();
      const terminal = await f.launch();
      await terminal.sendText("Continue the current turn.");
      await terminal.waitForPane((pane) => pane.includes(TURN_REPLY) && hasEmptyComposer(pane), 20_000);
      await Bun.sleep(2000);
      expect(f.summaries).toHaveLength(0);
      expect(f.checkpoints()).toBe(0);
      expect(readFileSync(f.traceLog, "utf8")).not.toContain("warm_committed");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 90_000);

  const freshEnv = { FX_AUTO_COMPACT_PERCENT: "20", FX_AUTO_COMPACT_WARM_PERCENT: "10" };

  async function heldWarmTurn(f: Awaited<ReturnType<typeof fixture>>) {
    const terminal = await f.launch();
    await terminal.sendText("First turn.");
    await terminal.waitForPane((pane) => pane.includes(FIRST_END) && hasEmptyComposer(pane), 20_000);
    f.adoptSession();
    expect(f.summaries).toHaveLength(0);
    f.hold(true);
    await terminal.sendText("Continue the current turn.");
    await until(() => f.summaries.length === 1, "held warm summary request");
    await terminal.waitForPane((pane) => pane.includes(TURN_REPLY) && /Compacting/.test(pane) && hasEmptyComposer(pane), 10_000);
    expect(f.checkpoints()).toBe(0);
    f.phase("next");
    return terminal;
  }

  test("the reply stays visible and a prompt submitted during a held warm compaction waits, then runs with the compacted context", async () => {
    const f = await fixture(true, freshEnv);
    let passed = false;
    try {
      const terminal = await heldWarmTurn(f);
      const steer = "WARM_PROMPT_DURING_COMPACTION_7d20";
      await terminal.sendText(steer);
      const ordinaryBefore = f.ordinary();
      await Bun.sleep(1500);
      expect(f.ordinary()).toBe(ordinaryBefore);
      expect(f.requestsContaining(steer)).toHaveLength(0);
      f.release(FRESH_HANDOFF);
      await until(() => f.requestsContaining(steer).length > 0, "prompt request after warm compaction");
      expect(f.requestsContaining(steer)[0]).toContain("WARM_HANDOFF_91c4");
      await terminal.waitForPane((pane) => pane.includes(NEXT_REPLY) && hasEmptyComposer(pane), 20_000);
      expect(f.checkpoints()).toBe(1);
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 120_000);

  test("a prompt that has waited past the deadline cancels the warm compaction and runs", async () => {
    const f = await fixture(true, freshEnv);
    let passed = false;
    try {
      const terminal = await heldWarmTurn(f);
      const waiting = "WARM_PROMPT_PAST_DEADLINE_4e18";
      await terminal.sendText(waiting);
      const started = Date.now();
      await until(() => f.requestsContaining(waiting).length > 0, "prompt request after the deadline", 30_000);
      expect(Date.now() - started).toBeGreaterThanOrEqual(7000);
      expect(f.checkpoints()).toBe(0);
      await terminal.waitForPane((pane) => pane.includes(NEXT_REPLY) && hasEmptyComposer(pane), 20_000);
      expect(readFileSync(f.traceLog, "utf8")).toContain("prompt_waiting_deadline");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 120_000);
});
