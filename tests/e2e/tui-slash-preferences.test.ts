import { afterEach, describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TMUX_SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const CLIPBOARD_PROGRAM = process.platform === "darwin"
  ? "pbcopy"
  : process.platform === "linux"
    ? "xclip"
    : null;
const URL_OPEN_PROGRAM = process.platform === "darwin"
  ? "open"
  : process.platform === "linux"
    ? "xdg-open"
    : null;

interface FakeGatewayServer {
  baseUrl: string;
  chatUrl: string;
  stop: () => void;
}

let session: TmuxSession | null = null;
let gateway: FakeGatewayServer | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
  if (gateway) { gateway.stop(); gateway = null; }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function launchNoKeyAndWait(): Promise<{
  terminal: TmuxSession;
  stderrPath: string;
  workspace: string;
}> {
  const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(home);
  mkdirSync(workspace);
  tempDirs.push(root);
  const terminal = await TmuxSession.create({
    cwd: workspace,
    stderrPath,
    isolated: true,
    env: {
      HOME: home,
      FX_SOUND: "0",
      AI_GATEWAY_API_KEY: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_PERMISSION_MODE: undefined,
      FX_SKIP_ONBOARDING: "1",
      VERCEL_OIDC_TOKEN: undefined,
    },
  });
  await terminal.waitForText("Run /help for commands", 10_000);
  await terminal.waitForStableComposer(10_000);
  return { terminal, stderrPath, workspace };
}

async function launchFakeGatewayAndWait(
  fake: FakeGatewayServer,
): Promise<{
  terminal: TmuxSession;
  stderrPath: string;
  workspace: string;
}> {
  const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-gateway-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(home);
  mkdirSync(workspace);
  tempDirs.push(root);
  const terminal = await TmuxSession.create({
    cwd: workspace,
    stderrPath,
    isolated: true,
    env: {
      HOME: home,
      FX_SOUND: "0",
      AI_GATEWAY_API_KEY: "slash-preferences-fake-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: fake.baseUrl,
      FX_GATEWAY_CHAT_URL: fake.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: fake.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${fake.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_PERMISSION_MODE: "full-access",
    },
  });
  await terminal.waitForComposer(10_000);
  return { terminal, stderrPath, workspace };
}

describe.skipIf(TMUX_SKIP)("tui: preference slash commands", () => {
  test(
    "/alias reports aliases are not configurable",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;
      await session.sendText("/alias");
      const pane = await session.waitForText("Aliases are not yet configurable.", 5_000);
      expect(pane).toContain("Aliases are not yet configurable.");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/feedback reports the feedback URL",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-feedback-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const binDir = join(root, "bin");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home);
      mkdirSync(workspace);
      tempDirs.push(root);
      if (URL_OPEN_PROGRAM !== null) {
        mkdirSync(binDir);
        writeFileSync(join(binDir, URL_OPEN_PROGRAM), "#!/bin/sh\nexit 0\n");
        chmodSync(join(binDir, URL_OPEN_PROGRAM), 0o755);
      }
      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        isolated: true,
        env: {
          HOME: home,
          FX_SOUND: "0",
          AI_GATEWAY_API_KEY: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_PERMISSION_MODE: undefined,
          FX_SKIP_ONBOARDING: "1",
          VERCEL_OIDC_TOKEN: undefined,
          PATH: URL_OPEN_PROGRAM === null
            ? process.env.PATH ?? ""
            : `${binDir}:${process.env.PATH ?? ""}`,
        },
      });
      await session.waitForText("Run /help for commands", 10_000);
      await session.waitForStableComposer(10_000);

      await session.sendText("/feedback");
      const pane = await session.waitForText("https://fx.sh/feedback", 10_000);
      expect(pane).toContain("https://fx.sh/feedback");
      if (URL_OPEN_PROGRAM !== null) {
        // The platform opener is stubbed to exit 0 within the launch bound,
        // so the success branch is deterministic.
        expect(pane).toContain("Opened https://fx.sh/feedback.");
      } else {
        expect(pane).toContain(
          "Could not open https://fx.sh/feedback. Open it manually.",
        );
      }
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/feedback stays responsive while the opener hangs",
    async () => {
      if (URL_OPEN_PROGRAM === null) throw new Error("unsupported url opener platform");
      const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-feedback-hang-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const binDir = join(root, "bin");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home);
      mkdirSync(workspace);
      mkdirSync(binDir);
      writeFileSync(join(binDir, URL_OPEN_PROGRAM), "#!/bin/sh\nexec sleep 30\n");
      chmodSync(join(binDir, URL_OPEN_PROGRAM), 0o755);
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        isolated: true,
        env: {
          HOME: home,
          FX_SOUND: "0",
          AI_GATEWAY_API_KEY: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_PERMISSION_MODE: undefined,
          FX_SKIP_ONBOARDING: "1",
          VERCEL_OIDC_TOKEN: undefined,
          PATH: `${binDir}:${process.env.PATH ?? ""}`,
        },
      });
      await session.waitForText("Run /help for commands", 10_000);
      await session.waitForStableComposer(10_000);

      await session.sendText("/feedback");
      const pane = await session.waitForText("Opened https://fx.sh/feedback.", 5_000);
      expect(pane).toContain("https://fx.sh/feedback");
      await session.sendKeys("probe");
      const typed = await session.waitForText("probe", 5_000);
      expect(composerContains(typed, "probe")).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/copy reports the missing assistant reply state",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;
      await session.sendText("/copy");
      const pane = await session.waitForText("No assistant reply to copy.", 5_000);
      expect(pane).toContain("No assistant reply to copy.");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/undo reports empty state and reverts a tracked file creation",
    async () => {
      let requestCount = 0;
      gateway = startDynamicFakeGateway(() => {
        requestCount += 1;
        if (requestCount === 1) {
          return fakeGatewayToolCall("undo_write_1", "write_file", {
            path: "undo-target.txt",
            content: "undo fixture\n",
          });
        }
        return fakeGatewayFinalText("UNDO_FIXTURE_DONE");
      });
      const launched = await launchFakeGatewayAndWait(gateway);
      session = launched.terminal;

      await session.sendText("/undo");
      await session.waitForText("Nothing to undo.", 5_000);

      const target = join(launched.workspace, "undo-target.txt");
      await session.sendText("Create undo-target.txt with the fixture content.");
      await session.waitForText("UNDO_FIXTURE_DONE", 20_000);
      await session.waitForComposer(10_000);
      expect(readFileSync(target, "utf8")).toBe("undo fixture\n");

      await session.sendText("/undo");
      const pane = await session.waitForText("(was newly created)", 5_000);
      expect(pane).toContain("(was newly created)");
      expect(existsSync(target)).toBe(false);
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/statusline opens the menu, toggles an item, and shows usage",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;

      await session.sendText("/statusline");
      const menu = await session.waitForText("←→ change", 5_000);
      expect(menu).toContain("change");

      await session.sendKeys("Escape");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);

      await session.sendText("/statusline context");
      const toggled = await session.waitForText(/context: (on|off)/, 5_000);
      expect(toggled).toMatch(/statusline: context: (on|off)/);

      await session.sendText("/statusline bogus");
      const usage = await session.waitForText(
        "usage: /statusline [context|session|workspace]",
        5_000,
      );
      expect(usage).toContain("usage: /statusline [context|session|workspace]");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/sound off reports sound state without enabling sound",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;
      await session.sendText("/sound off");
      const pane = await session.waitForText("sound: off", 5_000);
      expect(pane).toContain("sound: off");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/paste reports the clipboard image surface",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;
      await session.sendText("/paste");
      if (process.platform === "darwin") {
        await session.waitForText("no image found on clipboard", 5_000);
      }
      const recovered = await session.waitForComposer(5_000);
      expect(hasEmptyComposer(recovered)).toBe(true);
      if (process.platform !== "darwin") {
        // Off macOS loadClipboardImageAttachment returns error.Unsupported and
        // attachClipboard surfaces the unavailable notice.
        const scrollback = await session.captureFullScrollback();
        expect(scrollback).toContain("Clipboard image paste is not available on this platform.");
        expect(scrollback).not.toContain("no image found on clipboard");
        expect(scrollback).not.toContain("failed to paste clipboard image");
      }
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/fast reports fast-mode availability",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;
      await session.sendText("/fast");
      const pane = await session.waitForText(
        "This model does not come with a fast mode.",
        5_000,
      );
      expect(pane).toContain("This model does not come with a fast mode.");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/stats renders render metrics",
    async () => {
      const launched = await launchNoKeyAndWait();
      session = launched.terminal;
      await session.sendText("/stats");
      await session.waitForText("ansi_bytes=", 5_000);
      const scrollback = await session.captureFullScrollback();
      for (const field of [
        "ansi_bytes=",
        "redraws=",
        "debounced_resizes=",
        "footer_updates=",
        "stream_chunks=",
      ]) {
        expect(scrollback).toContain(field);
      }
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});

describe.skipIf(TMUX_SKIP || CLIPBOARD_PROGRAM === null)("tui: clipboard-backed slash command", () => {
  test(
    "/trace copies a redaction-ready trace report to the clipboard",
    async () => {
      if (CLIPBOARD_PROGRAM === null) throw new Error("unsupported clipboard platform");
      const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-trace-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const binDir = join(root, "bin");
      const traceDir = join(root, "tmp");
      const capturePath = join(root, "clipboard.txt");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home);
      mkdirSync(workspace);
      mkdirSync(binDir);
      mkdirSync(traceDir);
      writeFileSync(join(binDir, CLIPBOARD_PROGRAM), "#!/bin/sh\n/bin/cat > \"$FX_TEST_CLIPBOARD_CAPTURE\"\n");
      chmodSync(join(binDir, CLIPBOARD_PROGRAM), 0o755);
      if (process.platform === "linux") {
        // Stub every clipboard tool name so whichever candidate the runtime
        // probes first records the copy deterministically.
        for (const name of ["wl-copy", "xsel"]) {
          writeFileSync(join(binDir, name), "#!/bin/sh\n/bin/cat > \"$FX_TEST_CLIPBOARD_CAPTURE\"\n");
          chmodSync(join(binDir, name), 0o755);
        }
      }
      tempDirs.push(root);

      session = await TmuxSession.create({
        cwd: workspace,
        stderrPath,
        isolated: true,
        width: 200,
        env: {
          HOME: home,
          FX_SOUND: "0",
          AI_GATEWAY_API_KEY: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_PERMISSION_MODE: undefined,
          FX_SKIP_ONBOARDING: "1",
          VERCEL_OIDC_TOKEN: undefined,
          FX_TEST_CLIPBOARD_CAPTURE: capturePath,
          TMPDIR: traceDir,
          PATH: `${binDir}:${process.env.PATH ?? ""}`,
        },
      });
      await session.waitForText("Run /help for commands", 10_000);
      await session.waitForStableComposer(10_000);

      await session.sendText("/trace");
      const pane = await session.waitForText("Review and redact it before sharing.", 20_000);
      if (process.platform === "linux") {
        expect(pane).toContain("Trace copied to clipboard.");
        const traceFiles = readdirSync(traceDir).filter((name) =>
          name.startsWith("fx-trace-") && name.endsWith(".md")
        );
        expect(traceFiles.length).toBe(1);
        const recorded = readFileSync(capturePath);
        const saved = readFileSync(join(traceDir, traceFiles[0]));
        expect(recorded.equals(saved)).toBe(true);
      } else {
        // macOS publishes the file reference through osascript, which the
        // stub cannot intercept; keep the disposition loose there.
        expect(pane).toMatch(
          /Trace copied to clipboard\.|Trace saved at |Clipboard copy failed\./,
        );
      }
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});

describe.skipIf(TMUX_SKIP || process.platform !== "linux")("tui: /trace linux clipboard fallbacks", () => {
  async function launchTraceFallbackSession(
    root: string,
    binDir: string,
  ): Promise<{ stderrPath: string }> {
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(home);
    mkdirSync(workspace);
    tempDirs.push(root);
    session = await TmuxSession.create({
      cwd: workspace,
      stderrPath,
      isolated: true,
      width: 200,
      env: {
        HOME: home,
        FX_SOUND: "0",
        AI_GATEWAY_API_KEY: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_PERMISSION_MODE: undefined,
        FX_SKIP_ONBOARDING: "1",
        VERCEL_OIDC_TOKEN: undefined,
        PATH: binDir,
      },
    });
    await session.waitForText("Run /help for commands", 10_000);
    await session.waitForStableComposer(10_000);
    return { stderrPath };
  }

  test(
    "/trace saves the report when no clipboard tool exists",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-trace-empty-"));
      const binDir = join(root, "empty-bin");
      mkdirSync(binDir);
      const launched = await launchTraceFallbackSession(root, binDir);

      await session.sendText("/trace");
      const pane = await session.waitForText("Trace saved at ", 20_000);
      expect(pane).not.toContain("Trace copied to clipboard.");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/trace saves the report when the clipboard tool exits nonzero",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-slash-preferences-trace-fail-"));
      const binDir = join(root, "bin");
      mkdirSync(binDir);
      for (const name of ["wl-copy", "xclip", "xsel"]) {
        writeFileSync(join(binDir, name), "#!/bin/sh\nexit 1\n");
        chmodSync(join(binDir, name), 0o755);
      }
      const launched = await launchTraceFallbackSession(
        root,
        `${binDir}:${process.env.PATH ?? ""}`,
      );

      await session.sendText("/trace");
      const pane = await session.waitForText("Trace saved at ", 20_000);
      expect(pane).not.toContain("Trace copied to clipboard.");
      expect(hasEmptyComposer(await session.waitForComposer(5_000))).toBe(true);
      expect(session.isAlive()).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
