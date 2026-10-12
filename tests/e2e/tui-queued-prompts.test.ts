import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let root: string | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
});

async function waitFor(predicate: () => boolean, description: string): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < TIMEOUT) {
    if (predicate()) return;
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for ${description}.`);
}

function heldResponse(state: { started: boolean; release?: () => void }): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        state.started = true;
        controller.enqueue(encoder.encode(
          `data: ${JSON.stringify({ type: "text-delta", id: "held", delta: "HELD_TURN\n" })}\n\n`,
        ));
        timer = setInterval(() => controller.enqueue(encoder.encode(": held\n\n")), 50);
        state.release = () => {
          if (timer) clearInterval(timer);
          controller.enqueue(encoder.encode(
            'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n',
          ));
          controller.close();
        };
      },
      cancel() {
        if (timer) clearInterval(timer);
      },
    }),
    { headers: { "content-type": "text/event-stream" } },
  );
}

describe.skipIf(!tmuxAvailable())("tui: queued prompts", () => {
  test("Ctrl+Q and Tab queue prompts for after the turn and Alt+Up edits the newest", async () => {
    root = realpathSync(mkdtempSync(join(tmpdir(), "fx-queued-prompts-")));
    const home = join(root, "home"), workspace = join(root, "workspace");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(home, ".fx", "settings.json"), "{}");

    const held: { started: boolean; release?: () => void } = { started: false };
    gateway = startFakeGateway([
      () => heldResponse(held),
      fakeGatewayFinalText("QUEUE_ALPHA_DONE"),
      fakeGatewayFinalText("QUEUE_BETA_DONE"),
    ]);
    session = await TmuxSession.create({
      cwd: workspace,
      stderrPath: join(root, "stderr.log"),
      isolated: true,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-queued-prompts-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      },
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Hold this response.");
    await waitFor(() => held.started, "held response");

    await session.sendLiteral("QUEUED_ALPHA");
    await session.sendKeys("C-q");
    await session.sendLiteral("QUEUED_BETA");
    await session.sendKeys("Tab");
    await session.sendLiteral("QUEUED_GAMMA");
    await session.sendKeys("C-q");
    await session.waitForText("3 waiting", TIMEOUT);
    expect(gateway.requests.length).toBe(1);

    await session.sendKeys("M-Up");
    await session.waitForText("QUEUED_GAMMA", TIMEOUT);
    await session.sendKeys("C-u");

    held.release!();
    await waitFor(() => gateway!.requests.length >= 3, "queued turns");
    await session.waitForText("QUEUE_BETA_DONE", TIMEOUT);
    expect(gateway.requests[1]!.body).toContain("QUEUED_ALPHA");
    expect(gateway.requests[2]!.body).toContain("QUEUED_BETA");
    expect(gateway.requests[2]!.body).not.toContain("QUEUED_GAMMA");
    expect(gateway.requests.length).toBe(3);
  }, TIMEOUT * 2);
});
