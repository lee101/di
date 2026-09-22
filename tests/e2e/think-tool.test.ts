import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayTitleDefault, TITLE_GENERATION_MARKER } from "./tmux-helpers";

const TIMEOUT = 15_000;
const OUTER_MODEL = "openai/gpt-5";

type GatewayRequest = {
  body: string;
  headers: Headers;
};

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

type FakeGateway = {
  chatUrl: string;
  baseUrl: string;
  requests: GatewayRequest[];
  stop: () => void;
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
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-think-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission: {} }));
    chmodSync(join(home, ".fx"), 0o700);
    chmodSync(join(home, ".fx", "settings.json"), 0o600);
  return { root, home, workspace: realpathSync(workspace) };
}

function fakeGatewayEnv(
  root: IsolatedRoot,
  gateway: FakeGateway,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_E2E_GATEWAY_CREDITS_URL: undefined,
    FX_MODEL: OUTER_MODEL,
  };
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

describe("think scratchpad fixture", () => {
  test(
    "acknowledges scripted thoughts and keeps no state",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerToolCalls([
          {
            id: "think_1",
            name: "think",
            input: { thought: "Sequence the refactor before editing either file." },
          },
          {
            id: "think_2",
            name: "think",
            input: { thought: "Sequence the refactor before editing either file." },
          },
        ]),
        outerText("Both scratchpad steps were acknowledged."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Think through the refactor plan."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        const json = JSON.parse(result.stdout.trim()) as {
          output: string;
          tool_calls: Array<Record<string, unknown>>;
        };
        expect(json.output).toContain("Both scratchpad steps were acknowledged.");
        expect(gateway.requests).toHaveLength(2);

        // Repeated identical thoughts produce identical acknowledgments: the
        // scratchpad keeps no state between calls.
        const first = toolResultText(gateway.requests[1]!.body, "think_1").trim();
        const second = toolResultText(gateway.requests[1]!.body, "think_2").trim();
        expect(first).toBe("Thought acknowledged.");
        expect(second).toBe(first);

        // No metadata, no side effects, no workspace changes.
        expect(json.tool_calls).toHaveLength(2);
        for (const call of json.tool_calls) {
          expect(call.name).toBe("think");
          expect(call.status).toBe("success");
          expect(Object.keys(call).sort()).toEqual(["name", "status"]);
        }
        expect(readdirSync(root.workspace)).toHaveLength(0);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "rejects invalid think arguments before acknowledging",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        outerToolCalls([
          {
            id: "think_bad",
            name: "think",
            input: { note: "wrong field" },
          },
        ]),
        outerText("Invalid scratchpad arguments were rejected."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Think with invalid arguments."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        expect(result.code).toBe(0);
        const rendered = toolResultText(gateway.requests[1]!.body, "think_bad");
        expect(rendered).toBe("think field \"note\" is not supported");
        expect(rendered).not.toContain("Thought acknowledged.");
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
