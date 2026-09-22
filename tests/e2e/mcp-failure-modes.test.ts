import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx, type FxRunResult } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 20_000;
const MODEL = "openai/gpt-5";
const MCP_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
const TOOL_NAME = "mcp_fixture_echo";

const cleanups: Array<() => void> = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
};

type GatewayEndpoint = {
  baseUrl: string;
  chatUrl: string;
};

type FailureMode = "stall_startup" | "crash_always" | "stall_operation";

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

function createRoot(label: string, mode: FailureMode): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-mcp-failure-${label}-`)));
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
            FX_MCP_PID_PATH: join(root, "mcp.pid"),
            FX_MCP_PROTOCOL_VERSION: "2026-07-28",
            FX_MCP_MODE: mode,
            FX_MCP_RESULT_TEXT: "FIXTURE_ECHO_RESULT",
          },
          startup_timeout_ms: mode === "stall_startup" ? 100 : undefined,
          operation_timeout_ms: mode === "stall_operation" ? 100 : undefined,
          restart_limit: 0,
        },
      },
    }),
  );
  return { root, home, workspace };
}

function fixtureEnv(root: FixtureRoot, activeGateway: GatewayEndpoint): Record<string, string | undefined> {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-mcp-failure-key",
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

type ToolCallStatus = { name: string; status: string };

async function runFailureMode(
  label: string,
  mode: FailureMode,
): Promise<{ result: FxRunResult; selectResult: string; callResult: string }> {
  const root = createRoot(label, mode);
  const selectCallId = "select_mcp";
  const callId = "call_mcp";
  const activeGateway = startFakeGateway([
    fakeGatewayToolCall(selectCallId, "mcp_select_tool", { name: TOOL_NAME }),
    fakeGatewayToolCall(callId, TOOL_NAME, { text: "hello" }),
    fakeGatewayFinalText(`${label} degraded without hanging.`),
  ], {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
  cleanups.push(() => activeGateway.stop());

  const result = await runFx(
    ["ask", "--json", "--auto", "--no-save", "Use the MCP echo tool."],
    {
      cwd: root.workspace,
      env: fixtureEnv(root, activeGateway),
      timeoutMs: TIMEOUT,
    },
  );
  return {
    result,
    selectResult: toolResultText(activeGateway.requests[1]!.body, selectCallId),
    callResult: toolResultText(activeGateway.requests[2]!.body, callId),
  };
}

describe("mcp adversarial failure modes", () => {
  test(
    "server hang during init degrades tool discovery without hanging the run",
    async () => {
      const { result, selectResult, callResult } = await runFailureMode(
        "startup-hang",
        "stall_startup",
      );
      expect(result.timedOut).toBe(false);
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("startup-hang degraded without hanging.");
      const toolCalls = (JSON.parse(result.stdout) as { tool_calls: ToolCallStatus[] }).tool_calls;
      expect(toolCalls.filter((call) => call.status === "error").length).toBeGreaterThanOrEqual(1);
      expect(selectResult).toContain('"type":"tool_execution_failed"');
      expect(selectResult).toContain('"error":"McpConnectionTimedOut"');
      expect(callResult).toBe("Unsupported tool: mcp_fixture_echo");
    },
    TIMEOUT,
  );

  test(
    "server crash after init degrades the tool call without hanging the run",
    async () => {
      const { result, selectResult, callResult } = await runFailureMode(
        "crash",
        "crash_always",
      );
      expect(result.timedOut).toBe(false);
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("crash degraded without hanging.");
      const toolCalls = (JSON.parse(result.stdout) as { tool_calls: ToolCallStatus[] }).tool_calls;
      expect(toolCalls.some((call) => call.name === TOOL_NAME && call.status === "error")).toBe(true);
      expect(selectResult).toContain("Selected dynamic MCP tool `mcp_fixture_echo`");
      expect(callResult).toContain('"type":"tool_execution_failed"');
      expect(callResult).toContain('"error":"McpConnectionClosed"');
    },
    TIMEOUT,
  );

  test(
    "delayed tool response degrades with a structured timeout error",
    async () => {
      const { result, callResult } = await runFailureMode(
        "delayed-response",
        "stall_operation",
      );
      expect(result.timedOut).toBe(false);
      expect(result.code).toBe(0);
      expect(result.stdout).toContain("delayed-response degraded without hanging.");
      expect(callResult).toContain('"type":"tool_execution_failed"');
      expect(callResult).toContain('"error":"McpRequestTimedOut"');
    },
    TIMEOUT,
  );
});
