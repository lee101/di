import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeShellRun,
  startDynamicFakeGateway,
} from "../tests/e2e/tmux-helpers";

const bin = resolve(process.env.FX_BIN ?? "zig-out/bin/di");
const calls = Number(process.env.CALLS ?? 30);
const cmd = process.env.TOOL_CMD ?? "seq 1 40000";
const final = process.env.FINAL ?? "done";
const extra = process.argv.slice(2);
const root = realpathSync(mkdtempSync(join(tmpdir(), "perf-bench-")));
const home = join(root, "home");
const ws = join(root, "ws");
mkdirSync(home);
mkdirSync(ws);
writeFileSync(join(ws, "big.txt"), "x".repeat(200) + "\n");
let n = 0;
const gw = startDynamicFakeGateway(() => {
  n++;
  const turn = Math.floor((n - 1) / (calls + 1));
  const idx = (n - 1) % (calls + 1);
  if (idx < calls) return fakeShellRun(`c${n}`, `${cmd} # ${n}`);
  return fakeGatewayFinalText(process.env[`FINAL_${turn}`] ?? final);
});
const env = {
  ...process.env,
  HOME: home,
  AI_GATEWAY_API_KEY: "fake",
  FX_DISABLE_KEYCHAIN: "1",
  FX_SKIP_ONBOARDING: "1",
  FX_MODEL: FAKE_GATEWAY_MODEL,
  FX_PERMISSION_MODE: "auto",
  FX_GATEWAY_BASE_URL: gw.baseUrl,
  FX_GATEWAY_CHAT_URL: gw.chatUrl,
  FX_E2E_GATEWAY_CHAT_URL: gw.chatUrl,
  FX_E2E_GATEWAY_MODELS_URL: `${gw.baseUrl}/coding-agent/v1/models`,
  NO_COLOR: "1",
  FX_PROVIDER: "gateway",
};
const wrap = process.env.WRAP ? process.env.WRAP.split(" ") : [];
const t0 = performance.now();
const p = Bun.spawn([...wrap, bin, "ask", "--yolo", "--no-color", ...extra], {
  cwd: ws,
  env,
  stdout: "pipe",
  stderr: "pipe",
});
const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
await p.exited;
console.log(JSON.stringify({ code: p.exitCode, ms: Math.round(performance.now() - t0), requests: n, home, ws }));
console.log("STDOUT>", out.slice(-600));
console.log("STDERR>", err.slice(-1500));
gw.stop();
