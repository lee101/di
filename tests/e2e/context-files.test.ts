import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, startFakeGateway } from "./tmux-helpers";

const TIMEOUT = 15_000;
const MODEL = "openai/gpt-5";

interface IsolatedRoot {
  root: string;
  home: string;
  workspace: string;
}

interface GatewayEndpoint {
  baseUrl: string;
  chatUrl: string;
}

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-context-files-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
  return { root, home, workspace: realpathSync(workspace) };
}

function fakeGatewayEnv(root: IsolatedRoot, gateway: GatewayEndpoint) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_E2E_GATEWAY_CREDITS_URL: undefined,
    FX_MODEL: MODEL,
  };
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const part = content as { text?: unknown; content?: unknown };
    return contentText(part.text ?? part.content ?? "");
  }
  return "";
}

function promptText(body: string): string {
  const request = JSON.parse(body) as {
    prompt: Array<{ content?: unknown }>;
  };
  return request.prompt.map((message) => contentText(message.content)).join("\n");
}

describe("context files", () => {
  test("ask sends every ecosystem root rule file in discovery order with content dedup", async () => {
    const root = createIsolatedRoot();
    writeFileSync(
      join(root.workspace, "AGENTS.md"),
      "AGENTS_ROOT_MARKER prefer the widget builder",
    );
    const claudeBody = "CLAUDE_ROOT_MARKER keep functions tiny";
    writeFileSync(join(root.workspace, "CLAUDE.md"), claudeBody);
    writeFileSync(join(root.workspace, "GEMINI.md"), claudeBody);
    writeFileSync(
      join(root.workspace, ".cursorrules"),
      "CURSOR_ROOT_MARKER indent with tabs",
    );

    const gateway = startFakeGateway([fakeGatewayFinalText("Context noted.")]);
    try {
      const result = await runFx(
        ["ask", "--auto", "--json", "--no-save", "Reply with a short confirmation."],
        { cwd: root.workspace, env: fakeGatewayEnv(root, gateway) },
      );
      expect(result.code).toBe(0);
      expect(gateway.requests).toHaveLength(1);
      const text = promptText(gateway.requests[0]!.body);

      for (const marker of [
        "AGENTS_ROOT_MARKER",
        "CLAUDE_ROOT_MARKER",
        "CURSOR_ROOT_MARKER",
      ]) {
        expect(text).toContain(marker);
      }
      expect(text.indexOf("AGENTS_ROOT_MARKER")).toBeLessThan(
        text.indexOf("CLAUDE_ROOT_MARKER"),
      );
      expect(text.indexOf("CLAUDE_ROOT_MARKER")).toBeLessThan(
        text.indexOf("CURSOR_ROOT_MARKER"),
      );

      for (const name of ["AGENTS.md", "CLAUDE.md", ".cursorrules"]) {
        expect(text).toContain(`<project-rules from="${join(root.workspace, name)}">`);
      }

      expect(text.split("CLAUDE_ROOT_MARKER").length - 1).toBe(1);
      expect(text).not.toContain(join(root.workspace, "GEMINI.md"));
    } finally {
      gateway.stop();
      rmSync(root.root, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
