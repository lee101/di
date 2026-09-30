import { mkdirSync, mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  startDynamicFakeGateway,
} from "../tests/e2e/tmux-helpers";

const bin = resolve(process.env.FX_BIN ?? "zig-out/bin/di");
const parallel = Number(process.env.PARALLEL ?? 4);
const cmd = process.env.TOOL_CMD ?? "sleep 0.3";
const root = realpathSync(mkdtempSync(join(tmpdir(), "perf-batch-")));
const home = join(root, "home");
const ws = join(root, "ws");
mkdirSync(home);
mkdirSync(ws);
let n = 0;
const gw = startDynamicFakeGateway(() => {
  n++;
  if (n > 1) return fakeGatewayFinalText("done");
  const events: object[] = [];
  for (let i = 0; i < parallel; i++) {
    events.push({
      type: "tool-call",
      toolCallId: `p${i}`,
      toolName: "shell",
      input: { request: { action: "run", command: `${cmd}; echo ${i}`, yield_time_ms: 30000 } },
    });
  }
  events.push({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
  return fakeGatewaySse(events);
});
const env = {
  ...process.env,
  HOME: home,
  AI_GATEWAY_API_KEY: "fake",
  FX_DISABLE_KEYCHAIN: "1",
  FX_SKIP_ONBOARDING: "1",
  FX_MODEL: FAKE_GATEWAY_MODEL,
  FX_PERMISSION_MODE: "auto",
  FX_PROVIDER: "gateway",
  FX_GATEWAY_BASE_URL: gw.baseUrl,
  FX_GATEWAY_CHAT_URL: gw.chatUrl,
  FX_E2E_GATEWAY_CHAT_URL: gw.chatUrl,
  FX_E2E_GATEWAY_MODELS_URL: `${gw.baseUrl}/coding-agent/v1/models`,
  NO_COLOR: "1",
};
const t0 = performance.now();
const p = Bun.spawn([bin, "ask", "--yolo", "--no-color", "run all"], { cwd: ws, env, stdout: "pipe", stderr: "pipe" });
const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
await p.exited;
console.log(JSON.stringify({ code: p.exitCode, ms: Math.round(performance.now() - t0), parallel, cmd }));
if (process.env.VERBOSE) console.log(err.slice(-800));
gw.stop();
