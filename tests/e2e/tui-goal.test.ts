import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TMUX_SKIP = !tmuxAvailable();
const TIMEOUT = 45_000;

let session: TmuxSession | null = null;
let gateway: { stop(): void } | null = null;
let root = "";

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
  if (gateway) { gateway.stop(); gateway = null; }
  if (root) { rmSync(root, { recursive: true, force: true }); root = ""; }
});

async function launch(fake: ReturnType<typeof startDynamicFakeGateway>) {
  gateway = fake;
  root = mkdtempSync(join(tmpdir(), "fx-tui-goal-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  session = await TmuxSession.create({
    cwd: workspace,
    isolated: true,
    env: {
      HOME: home,
      FX_SOUND: "0",
      AI_GATEWAY_API_KEY: "goal-fake-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_PROVIDER: "gateway",
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
  await session.waitForComposer(10_000);
  return { home, session };
}

function savedGoal(home: string) {
  const dir = join(home, ".fx", "goals");
  return { dir, files: readdirSync(dir), read: () => JSON.parse(readFileSync(join(dir, readdirSync(dir)[0]), "utf8")) };
}

describe.skipIf(TMUX_SKIP)("tui: /goal", () => {
  test("set, auto-continue to completion, show, clear", async () => {
    let n = 0;
    const fake = startDynamicFakeGateway(() => {
      n++;
      return n === 1
        ? fakeGatewayFinalText("step\nGOAL: continue\nPROGRESS: wrote first part")
        : fakeGatewayFinalText("done\nGOAL: complete\nPROGRESS: verified\nEVIDENCE: tests pass");
    });
    const { home, session: s } = await launch(fake);
    await s.sendText("/goal");
    await s.waitForText("No goal for this workspace", 5_000);
    await s.sendText("/goal ship the parser --turns 5 --tokens 100k");
    await s.waitForText("[goal] #2 complete", 30_000);
    expect(n).toBe(2);
    const saved = savedGoal(home);
    expect(saved.read().status).toBe("complete");
    expect(saved.read().turns).toBe(2);
    await s.sendText("/goal");
    await s.waitForText("goal complete: ship the parser", 5_000);
    await s.sendText("/goal clear");
    await s.waitForText("goal cleared", 5_000);
    expect(readdirSync(saved.dir).length).toBe(0);
    expect(s.isAlive()).toBe(true);
  }, TIMEOUT);

  test("pause stops continuation and usage errors are reported", async () => {
    let k = 0;
    const fake = startDynamicFakeGateway(async () => {
      k++;
      await Bun.sleep(600);
      return fakeGatewayFinalText(`x\nGOAL: continue\nPROGRESS: step number ${"a".repeat(k)}`);
    });
    const { home, session: s } = await launch(fake);
    await s.sendText("/goal budget");
    await s.waitForText("budget needs", 5_000);
    await s.sendText("/goal loop forever --turns 50");
    await s.waitForText("[goal] #1 continue", 20_000);
    await s.sendText("/goal pause");
    await s.waitForText("goal paused", 10_000);
    await Bun.sleep(1500);
    expect(savedGoal(home).read().status).toBe("paused");
    expect(existsSync(savedGoal(home).dir)).toBe(true);
  }, TIMEOUT);
});
