import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
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
if (process.env.MIRRORHOME) {
  const real = process.env.HOME ?? "";
  for (const name of readdirSync(real)) {
    if (name === ".fx") continue;
    try {
      symlinkSync(join(real, name), join(home, name));
    } catch {}
  }
}
if (process.env.PROFILE_SLEEP) writeFileSync(join(home, ".bash_profile"), `sleep ${process.env.PROFILE_SLEEP}\nexport FX_HEAVY=1\n`);
writeFileSync(join(ws, "big.txt"), "x".repeat(200) + "\n");
const t0 = performance.now();
let n = 0;
let child: { pid: number; kill(): void } | null = null;
const maxReq = Number(process.env.MAXREQ ?? 0);
const samples: string[] = [];
const gw = startDynamicFakeGateway(() => {
  n++;
  if (child && (n % 50 === 0 || (maxReq && n >= maxReq))) {
    try {
      const st = readFileSync(`/proc/${child.pid}/status`, "utf8");
      const rss = st.match(/VmRSS:\s+(\d+)/)?.[1];
      const hwm = st.match(/VmHWM:\s+(\d+)/)?.[1];
      samples.push(`req=${n} t=${Math.round(performance.now() - t0)}ms rss_kb=${rss}`);
    } catch {}
    if (maxReq && n >= maxReq) child.kill();
  }
  const turn = Math.floor((n - 1) / (calls + 1));
  const idx = (n - 1) % (calls + 1);
  if (idx < calls) return fakeShellRun(`c${n}`, process.env.SUFFIX ? `${cmd} # ${n}` : cmd);
  if (process.env.TURNS) {
    const last = turn >= Number(process.env.TURNS) - 1;
    const word = turn.toString(26).replace(/[0-9]/g, (d) => String.fromCharCode(97 + Number(d))).replace(/[a-p]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 10));
    return fakeGatewayFinalText(
      last
        ? "all done\nGOAL: complete\nPROGRESS: finished\nEVIDENCE: ran everything"
        : `worked\nGOAL: continue\nPROGRESS: step ${word}`,
    );
  }
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

const p = Bun.spawn([...wrap, bin, "ask", ...(process.env.NOYOLO ? [] : ["--yolo"]), "--no-color", ...extra], {
  cwd: ws,
  env,
  stdout: "pipe",
  stderr: "pipe",
});
child = p;
const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
await p.exited;
console.log(JSON.stringify({ code: p.exitCode, ms: Math.round(performance.now() - t0), requests: n, home, ws }));
if (samples.length) console.log("RSS_SAMPLES", samples.join(" | "));
console.log("STDOUT>", out.slice(-600));
console.log("STDERR>", err.slice(-1500));
gw.stop();
