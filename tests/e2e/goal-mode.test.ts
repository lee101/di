import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  while (gateways.length) gateways.pop()!.stop();
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

function setup(gateway: ReturnType<typeof startFakeGateway>, root?: { home: string; workspace: string }) {
  const dir = root ?? (() => {
    const base = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-goal-")));
    roots.push(base);
    const home = join(base, "home");
    const workspace = join(base, "workspace");
    mkdirSync(home);
    mkdirSync(workspace);
    return { home, workspace };
  })();
  return {
    ...dir,
    env: {
      HOME: dir.home,
      AI_GATEWAY_API_KEY: "fake-goal-key",
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_PROVIDER: "gateway",
      FX_PERMISSION_MODE: "auto",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    } as Record<string, string | undefined>,
  };
}

function goalFile(home: string): any {
  const dir = join(home, ".fx", "goals");
  const files = readdirSync(dir);
  expect(files.length).toBe(1);
  return JSON.parse(readFileSync(join(dir, files[0]), "utf8"));
}

const turn = (progress: string, signal = "continue", extra = "") =>
  fakeGatewayFinalText(`work\nGOAL: ${signal}\nPROGRESS: ${progress}\n${extra}`);

describe("di ask --auto-next-goal", () => {
  test("runs until the model reports complete with evidence", async () => {
    const gateway = startFakeGateway([
      turn("a"),
      turn("b"),
      turn("c", "complete", "EVIDENCE: tests pass"),
    ]);
    gateways.push(gateway);
    const env = setup(gateway);
    const r = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "--goal-turns", "10", "ship it"], {
      cwd: env.workspace,
      env: env.env,
      timeoutMs: TIMEOUT,
    });
    expect(r.code).toBe(0);
    expect(r.stderr.match(/\[goal\] #\d/g)?.length).toBe(3);
    expect(r.stderr).toContain("[goal] #3 complete");
    expect(goalFile(env.home).status).toBe("complete");
    expect(gateway.requests[0].body).toContain("<objective>");
    expect(gateway.requests[1].body).toContain("Continue the goal (turn 2)");
  }, TIMEOUT);

  test("complete without evidence does not stop the loop", async () => {
    const gateway = startFakeGateway([
      turn("claimed", "complete"),
      turn("verified", "complete", "EVIDENCE: ran suite"),
    ]);
    gateways.push(gateway);
    const env = setup(gateway);
    const r = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("[goal] #1 continue");
    expect(r.stderr).toContain("[goal] #2 complete");
  }, TIMEOUT);

  test("no-progress guard stops with exit 5", async () => {
    const gateway = startFakeGateway([turn("same"), turn("same"), turn("same"), turn("same"), turn("same")]);
    gateways.push(gateway);
    const env = setup(gateway);
    const r = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("stalled");
    expect(goalFile(env.home).status).toBe("stalled");
  }, TIMEOUT);

  test("turn budget stops with exit 4 and resumes after raising it", async () => {
    const gateway = startFakeGateway([
      turn("one"),
      turn("two"),
      turn("three", "complete", "EVIDENCE: e"),
    ]);
    gateways.push(gateway);
    const env = setup(gateway);
    const first = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "--goal-turns", "2", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(first.code).toBe(1);
    expect(goalFile(env.home).status).toBe("budget_limited");
    const refused = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(refused.code).toBe(1);
    expect(refused.stderr).toContain("budget exhausted");
    const resumed = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "--goal-turns", "5"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(resumed.code).toBe(0);
    expect(resumed.stderr).toContain("[goal] #3 complete");
    expect(gateway.requests[2].body).toContain("Resuming after 2 turns");
    expect(gateway.requests[2].body).toContain("two");
  }, TIMEOUT);

  test("blocked needs two consecutive reports", async () => {
    const gateway = startFakeGateway([
      turn("a", "blocked", "BLOCKER: need key"),
      turn("b", "blocked", "BLOCKER: need key"),
    ]);
    gateways.push(gateway);
    const env = setup(gateway);
    const r = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("[goal] #2 blocked");
    expect(goalFile(env.home).note).toBe("need key");
  }, TIMEOUT);

  test("external pause stops the loop", async () => {
    const gateway = startFakeGateway([
      turn("a"),
      async () => {
        const dir = join(env.home, ".fx", "goals");
        const file = join(dir, readdirSync(dir)[0]);
        const g = JSON.parse(readFileSync(file, "utf8"));
        g.status = "paused";
        writeFileSync(file, JSON.stringify(g) + "\n");
        return turn("b");
      },
      turn("c"),
    ]);
    gateways.push(gateway);
    const env = setup(gateway);
    const r = await runFx(["ask", "--yolo", "--no-color", "--auto-next-goal", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("externally");
    expect(existsSync(join(env.home, ".fx", "goals"))).toBe(true);
  }, TIMEOUT);

  test("rejects --no-save and budget flags without the goal flag", async () => {
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const env = setup(gateway);
    const a = await runFx(["ask", "--no-save", "--auto-next-goal", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(a.code).toBe(1);
    const b = await runFx(["ask", "--goal-turns", "3", "x"], { cwd: env.workspace, env: env.env, timeoutMs: TIMEOUT });
    expect(b.code).toBe(1);
  }, TIMEOUT);
});
