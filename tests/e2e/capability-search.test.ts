import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 20_000;
const MODEL = "openai/gpt-5";
const MCP_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");

const cleanups: Array<() => void> = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
  skillDirectory: string;
};

type GatewayEndpoint = {
  baseUrl: string;
  chatUrl: string;
};

type SearchOutput = {
  skills: Array<{ name: string; description: string; location: string }>;
  mcp_tools: Array<{ name: string; server: string; description?: string }>;
  counts: { skills: number; mcp_tools: number };
  total_matches: { skills: number; mcp_tools: number };
  state?: string;
};

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as {
    prompt: Array<{ content?: unknown }>;
  };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) =>
    part.type === "tool-result" && part.toolCallId === callId
  );
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return contentText(result.output);
}

function createRoot(label: string): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-capability-search-${label}-`)));
  cleanups.push(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
  writeFileSync(
    join(home, ".fx", "mcp.json"),
    JSON.stringify({
      mcp: {
        fixture: {
          type: "local",
          command: [process.execPath, MCP_FIXTURE],
          enabled: true,
          environment: {
            FX_MCP_PID_PATH: join(root, "fixture.pid"),
            FX_MCP_PROTOCOL_VERSION: "2026-07-28",
            FX_MCP_INITIAL_TOOL_NAME: "echo",
            FX_MCP_RESULT_TEXT: "FIXTURE_ECHO_RESULT",
          },
        },
        aux: {
          type: "local",
          command: [process.execPath, MCP_FIXTURE],
          enabled: true,
          environment: {
            FX_MCP_PID_PATH: join(root, "aux.pid"),
            FX_MCP_PROTOCOL_VERSION: "2026-07-28",
            FX_MCP_INITIAL_TOOL_NAME: "auxtool",
            FX_MCP_RESULT_TEXT: "AUX_ECHO_RESULT",
          },
        },
      },
    }),
  );
  const skillDirectory = join(workspace, ".agents", "skills", "mail-helper");
  mkdirSync(skillDirectory, { recursive: true });
  writeFileSync(
    join(skillDirectory, "SKILL.md"),
    "---\nname: mail-helper\ndescription: Send email messages through the shared outbox\n---\n\nMAIL_HELPER_BODY_SENTINEL\n",
  );
  const distractorDirectory = join(workspace, ".agents", "skills", "animation-vocabulary");
  mkdirSync(distractorDirectory, { recursive: true });
  writeFileSync(
    join(distractorDirectory, "SKILL.md"),
    "---\nname: animation-vocabulary\ndescription: Animation workflow for visual motion\n---\n\nDISTRACTOR_BODY_SENTINEL\n",
  );
  return { root, home, workspace, skillDirectory };
}

function fixtureEnv(root: FixtureRoot, activeGateway: GatewayEndpoint): Record<string, string | undefined> {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-capability-search-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "auto",
    FX_GATEWAY_BASE_URL: activeGateway.baseUrl,
    FX_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${activeGateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: MODEL,
  };
}

describe("capability_search skill and server scoping", () => {
  test(
    "capability_search returns skill-kind results without leaking skill bodies",
    async () => {
      const root = createRoot("skills");
      const searchCallId = "search_skills";
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall(searchCallId, "capability_search", {
          query: "send email messages",
        }),
        fakeGatewayFinalText("Skill search complete."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      cleanups.push(() => activeGateway.stop());

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Find the email workflow capability."],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, activeGateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Skill search complete.");
      const resultBody = toolResultText(activeGateway.requests[1]!.body, searchCallId);
      const search = JSON.parse(resultBody) as SearchOutput;
      expect(search.counts.skills).toBeGreaterThanOrEqual(1);
      expect(search.total_matches.skills).toBeGreaterThanOrEqual(1);
      const skill = search.skills.find((entry) => entry.name === "mail-helper");
      expect(skill).toBeDefined();
      expect(skill?.description).toBe("Send email messages through the shared outbox");
      expect(skill?.location).toContain("mail-helper");
      expect(search.skills.some((entry) => entry.name === "animation-vocabulary")).toBe(false);
      expect(resultBody).not.toContain("MAIL_HELPER_BODY_SENTINEL");
      expect(Array.isArray(search.mcp_tools)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "capability_search server restriction returns only the named server's tools",
    async () => {
      const root = createRoot("server-scope");
      const scopedCallId = "search_scoped";
      const otherCallId = "search_other";
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall(scopedCallId, "capability_search", {
          query: "echo text",
          server: "fixture",
        }),
        fakeGatewayToolCall(otherCallId, "capability_search", {
          query: "echo text",
          server: "aux",
        }),
        fakeGatewayFinalText("Server scoping complete."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      cleanups.push(() => activeGateway.stop());

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Search the MCP echo tools per server."],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, activeGateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Server scoping complete.");

      const scoped = JSON.parse(
        toolResultText(activeGateway.requests[1]!.body, scopedCallId),
      ) as SearchOutput;
      expect(scoped.counts.mcp_tools).toBeGreaterThanOrEqual(1);
      expect(scoped.mcp_tools.length).toBeGreaterThan(0);
      for (const tool of scoped.mcp_tools) {
        expect(tool.server).toBe("fixture");
      }
      expect(scoped.mcp_tools.map((tool) => tool.name)).toContain("mcp_fixture_echo");
      expect(scoped.mcp_tools.some((tool) => tool.server === "aux")).toBe(false);
      expect(scoped.mcp_tools.some((tool) => tool.name.includes("aux"))).toBe(false);
      expect(scoped.skills).toEqual([]);

      const other = JSON.parse(
        toolResultText(activeGateway.requests[2]!.body, otherCallId),
      ) as SearchOutput;
      expect(other.mcp_tools.length).toBeGreaterThan(0);
      for (const tool of other.mcp_tools) {
        expect(tool.server).toBe("aux");
      }
      expect(other.mcp_tools.map((tool) => tool.name)).toContain("mcp_aux_auxtool");
      expect(other.mcp_tools.some((tool) => tool.server === "fixture")).toBe(false);
      expect(other.skills).toEqual([]);
    },
    TIMEOUT,
  );
});
