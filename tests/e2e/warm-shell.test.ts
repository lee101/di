import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeShellRun,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  while (gateways.length) gateways.pop()!.stop();
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

function fixture(extraEnv: Record<string, string> = {}) {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-warm-")));
  roots.push(base);
  const home = join(base, "home");
  const workspace = join(base, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".bash_profile"),
    [
      'export PATH="$HOME/bin:$PATH"',
      "export FX_WARM_MARK=from-profile",
      "alias fxgreet='printf hello-alias'",
      "fxfunc() { printf \"func:%s\" \"$1\"; }",
      'printf x >> "$HOME/profile-runs"',
      "",
    ].join("\n"),
  );
  const gateway = startFakeGateway([
    fakeShellRun("a", 'fxgreet; printf " "; fxfunc 1; printf " %s" "$FX_WARM_MARK"; case ":$PATH:" in *":$HOME/bin:"*) printf " path";; esac'),
    fakeShellRun("b", "fxgreet; fxfunc 2"),
    fakeGatewayFinalText("done"),
  ]);
  gateways.push(gateway);
  return {
    home,
    workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake",
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_PROVIDER: "gateway",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      ...extraEnv,
    } as Record<string, string | undefined>,
  };
}

describe("warm user shell", () => {
  test("profile runs once for the snapshot, semantics preserved", async () => {
    const f = fixture();
    const r = await runFx(["ask", "--yolo", "--no-color", "run them"], { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT });
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("hello-alias func:1 from-profile path");
    expect(r.stderr).toContain("hello-aliasfunc:2");
    expect(readFileSync(join(f.home, "profile-runs"), "utf8")).toBe("x");
    expect(existsSync(join(f.home, ".fx", "cache", "shell-snapshot"))).toBe(true);
  }, TIMEOUT);

  test("FX_SHELL_SNAPSHOT=0 keeps the per-command login shell", async () => {
    const f = fixture({ FX_SHELL_SNAPSHOT: "0" });
    const r = await runFx(["ask", "--yolo", "--no-color", "run them"], { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT });
    expect(r.code).toBe(0);
    expect(r.stderr).toContain("hello-alias func:1 from-profile path");
    expect(readFileSync(join(f.home, "profile-runs"), "utf8")).toBe("xx");
    expect(existsSync(join(f.home, ".fx", "cache", "shell-snapshot"))).toBe(false);
  }, TIMEOUT);

  test("a second process reuses the cached snapshot without running the profile", async () => {
    const f = fixture();
    await runFx(["ask", "--yolo", "--no-color", "one"], { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT });
    expect(readFileSync(join(f.home, "profile-runs"), "utf8")).toBe("x");
    const gateway = startFakeGateway([fakeShellRun("c", "fxgreet"), fakeGatewayFinalText("done")]);
    gateways.push(gateway);
    const env = {
      ...f.env,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    };
    const r = await runFx(["ask", "--yolo", "--no-color", "two"], { cwd: f.workspace, env, timeoutMs: TIMEOUT });
    expect(r.stderr).toContain("hello-alias");
    expect(readFileSync(join(f.home, "profile-runs"), "utf8")).toBe("x");
  }, TIMEOUT);
});
