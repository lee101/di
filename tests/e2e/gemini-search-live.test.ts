import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayTitleDefault, TITLE_GENERATION_MARKER } from "./tmux-helpers";

const TIMEOUT = 60_000;
const OUTER_MODEL = "openai/gpt-5";

type GatewayRequest = {
  body: string;
  headers: Headers;
};

type FakeGateway = {
  chatUrl: string;
  baseUrl: string;
  requests: GatewayRequest[];
  stop: () => void;
};

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

function sse(events: object[], done = true) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      (done ? "data: [DONE]\n\n" : ""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function outerToolCalls(calls: Array<{ id: string; name: string; input: object }>) {
  return sse([
    ...calls.map((call) => ({
      type: "tool-call",
      toolCallId: call.id,
      toolName: call.name,
      input: call.input,
    })),
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

function outerText(text: string) {
  return sse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 11 },
        outputTokens: { total: 13 },
      },
    },
  ]);
}

function startFakeGateway(responses: Array<Response | Promise<Response>>): FakeGateway {
  const requests: GatewayRequest[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({
          data: [{ id: OUTER_MODEL, type: "language", tags: ["tool-use"] }],
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes(TITLE_GENERATION_MARKER)) {
        return fakeGatewayTitleDefault();
      }
      requests.push({ body, headers: req.headers });
      return await (responses.shift() ?? new Response("unexpected request", { status: 500 }));
    },
  });

  return {
    chatUrl: `http://127.0.0.1:${server.port}/v4/ai/language-model`,
    baseUrl: `http://127.0.0.1:${server.port}`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-gemini-live-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission: {} }));
    chmodSync(join(home, ".fx"), 0o700);
    chmodSync(join(home, ".fx", "settings.json"), 0o600);
  return { root, home, workspace: realpathSync(workspace) };
}

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

// Live-network/credentialed: one real Gemini API call with Google Search
// grounding. Structure assertions only; the outer model is scripted.
describe.skipIf(!process.env.GEMINI_API_KEY)("gemini_search live Gemini API", () => {
  test(
    "one real grounded call returns non-empty answer text and at least one source URL",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerToolCalls([
          {
            id: "gemini_live_1",
            name: "gemini_search",
            input: { query: "current stable Zig programming language release" },
          },
        ]),
        outerText("Live grounding completed."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Check the current stable Zig release."],
          {
            cwd: root.workspace,
            env: {
              HOME: root.home,
              AI_GATEWAY_API_KEY: "fake-e2e-key",
              VERCEL_OIDC_TOKEN: undefined,
              FX_GATEWAY_BASE_URL: gateway.baseUrl,
              FX_GATEWAY_CHAT_URL: gateway.chatUrl,
              FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
              FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
              FX_E2E_GATEWAY_CREDITS_URL: undefined,
              FX_MODEL: OUTER_MODEL,
              GEMINI_API_KEY: process.env.GEMINI_API_KEY,
              FX_GEMINI_BASE_URL: undefined,
              FX_GEMINI_SEARCH_MODEL: undefined,
            },
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        expect(gateway.requests).toHaveLength(2);
        const toolResult = toolResultText(gateway.requests[1]!.body, "gemini_live_1");

        expect(toolResult).toContain("Web search results for query:");
        const answerMarker = "hyperlinks.\n\n";
        const answerStart = toolResult.indexOf(answerMarker);
        const sourcesStart = toolResult.indexOf("\n\nSources:\n");
        expect(answerStart).toBeGreaterThan(-1);
        expect(sourcesStart).toBeGreaterThan(answerStart);
        const answerText = toolResult
          .slice(answerStart + answerMarker.length, sourcesStart)
          .trim();
        expect(answerText.length).toBeGreaterThan(0);
        expect(toolResult).toMatch(/- \[[^\]]+\]\(https?:\/\/[^\s)]+\)/);
        expect(toolResult).toContain("Queries executed:");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
