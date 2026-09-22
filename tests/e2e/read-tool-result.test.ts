import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 20_000;
const MODEL = "openai/gpt-5";
const MISSING_HANDLE = "fx-command-replay-00112233445566778899aabbccddeeff.bin";
const RANGE_COMMAND = `printf 'RANGE_HEAD${"x".repeat(60000)}RANGE_TAIL\\n'`;
// Stored capture = "[stdout]\n" + line with "\n" escaped as literal \x0a +
// "\n[/stdout]\n" = 9 + 60024 + 11 bytes.
const TOTAL_BYTES = 60044;
const TAIL_PAGE = "RANGE_TAIL\\x0a\n[/stdout]\n";

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

type CommandResult = { full_output_handle?: string; exit_code?: number };

type CommandOutputPage = {
  handle: string;
  startByte: number;
  endByte: number;
  totalBytes: number;
  page: string;
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

function parseCommandOutputPage(text: string): CommandOutputPage {
  const match = text.match(
    /^<command_output handle="([^"]+)" start_byte="(\d+)" end_byte="(\d+)" total_bytes="(\d+)">\n([\s\S]*)<\/command_output>$/,
  );
  if (!match) throw new Error(`Unexpected command output page: ${text}`);
  return {
    handle: match[1]!,
    startByte: Number(match[2]),
    endByte: Number(match[3]),
    totalBytes: Number(match[4]),
    page: match[5]!,
  };
}

function createRoot(label: string): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-read-tool-result-${label}-`)));
  cleanups.push(() => rmSync(root, { recursive: true, force: true }));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({}));
  return { root, home, workspace };
}

function fixtureEnv(root: FixtureRoot, activeGateway: GatewayEndpoint): Record<string, string | undefined> {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-read-tool-result-key",
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

describe("read_tool_result byte-range retrieval", () => {
  test(
    "byte-range reads return exact slices of captured command output",
    async () => {
      const root = createRoot("ranges");
      let handle = "";
      const head: string[] = [];
      const middle: string[] = [];
      const tail: string[] = [];
      const pastEnd: string[] = [];
      const activeGateway = startFakeGateway([
        fakeShellRun("run_1", RANGE_COMMAND),
        (body) => {
          const commandResult = JSON.parse(
            toolResultText(body, "run_1"),
          ) as CommandResult;
          expect(commandResult.exit_code).toBe(0);
          handle = commandResult.full_output_handle ?? "";
          expect(handle).toMatch(/^fx-command-replay-.+\.bin$/);
          return fakeGatewayToolCall("range_head", "read_tool_result", {
            request: { handle, start_byte: 10, byte_count: 10 },
          });
        },
        (body) => {
          head.push(toolResultText(body, "range_head"));
          return fakeGatewayToolCall("range_middle", "read_tool_result", {
            request: { handle, start_byte: 25, byte_count: 8 },
          });
        },
        (body) => {
          middle.push(toolResultText(body, "range_middle"));
          return fakeGatewayToolCall("range_tail", "read_tool_result", {
            request: { handle, start_byte: 60020, byte_count: 25 },
          });
        },
        (body) => {
          tail.push(toolResultText(body, "range_tail"));
          return fakeGatewayToolCall("range_past_end", "read_tool_result", {
            request: { handle, start_byte: 61000, byte_count: 16 },
          });
        },
        (body) => {
          pastEnd.push(toolResultText(body, "range_past_end"));
          return fakeGatewayFinalText("Byte ranges retrieved.");
        },
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      cleanups.push(() => activeGateway.stop());

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Run the byte range fixture once."],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, activeGateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Byte ranges retrieved.");

      const headPage = parseCommandOutputPage(head[0]!);
      expect(headPage.handle).toBe(handle);
      expect(headPage.startByte).toBe(10);
      expect(headPage.endByte).toBe(19);
      expect(headPage.totalBytes).toBe(TOTAL_BYTES);
      expect(headPage.page).toBe("RANGE_HEAD");

      const middlePage = parseCommandOutputPage(middle[0]!);
      expect(middlePage.startByte).toBe(25);
      expect(middlePage.endByte).toBe(32);
      expect(middlePage.totalBytes).toBe(TOTAL_BYTES);
      expect(middlePage.page).toBe("xxxxxxxx");

      const tailPage = parseCommandOutputPage(tail[0]!);
      expect(tailPage.startByte).toBe(60020);
      expect(tailPage.endByte).toBe(60044);
      expect(tailPage.totalBytes).toBe(TOTAL_BYTES);
      expect(tailPage.page).toBe(TAIL_PAGE);

      const pastEndPage = parseCommandOutputPage(pastEnd[0]!);
      expect(pastEndPage.totalBytes).toBe(TOTAL_BYTES);
      expect(pastEndPage.page).toBe("");
    },
    TIMEOUT,
  );

  test(
    "byte-range reads of a missing handle fail with a structured error",
    async () => {
      const root = createRoot("missing");
      const readCallId = "read_missing";
      const activeGateway = startFakeGateway([
        fakeGatewayToolCall(readCallId, "read_tool_result", {
          request: { handle: MISSING_HANDLE, start_byte: 1, byte_count: 16 },
        }),
        fakeGatewayFinalText("Missing handle inspected."),
      ], {
        models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      });
      cleanups.push(() => activeGateway.stop());

      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "Read the missing command output."],
        {
          cwd: root.workspace,
          env: fixtureEnv(root, activeGateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code).toBe(0);
      expect(result.stdout).toContain("Missing handle inspected.");
      const failure = toolResultText(activeGateway.requests[1]!.body, readCallId);
      expect(failure).toContain(
        `read_tool_result failed for handle ${MISSING_HANDLE}: ResultHandleNotFound.`,
      );
    },
    TIMEOUT,
  );
});
