import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const tempRoots: string[] = [];
let gateway: { stop(): void } | null = null;

afterEach(() => {
  gateway?.stop();
  gateway = null;
  for (const root of tempRoots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-shell-shape-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  chmodSync(join(home, ".fx"), 0o700);
  mkdirSync(workspace);
  tempRoots.push(root);
  return { home, workspace };
}

async function runShape(request: Record<string, unknown>) {
  const f = fixture();
  const fake = startFakeGateway([
    fakeGatewayToolCall("shape_1", "shell", { request }),
    fakeGatewayFinalText("SHAPE_DONE"),
  ]);
  gateway = fake;
  const result = await runFx(["ask", "--auto", "--json", "Run the fixture command."], {
    cwd: f.workspace,
    env: {
      HOME: f.home,
      AI_GATEWAY_API_KEY: "fake-shape-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_GATEWAY_BASE_URL: fake.baseUrl,
      FX_GATEWAY_CHAT_URL: fake.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
    },
    timeoutMs: TIMEOUT,
  });
  const output = JSON.parse(result.stdout.trim()) as {
    final_output: string;
    tool_calls: Array<{ name: string; status: string }>;
  };
  const followUp = JSON.stringify(fake.requests[1]?.body ?? "");
  return { result, output, followUp };
}

const bash = { kind: "executable", path: "/bin/bash" };

describe("shell request shapes", () => {
  test.each([
    ["shell with tty=false", { shell: { ...bash, clean_start: true }, tty: false }, "ignored because tty is not true"],
    ["shell without tty", { shell: bash }, "ignored because tty is not true"],
    ["profile and shell with tty=false", { profile: "clean", shell: bash, tty: false }, "ignored because tty is not true"],
    ["profile and shell with tty=true", { profile: "clean", shell: bash, tty: true }, "profile was ignored because shell was given"],
  ])("%s runs with a note", async (_name, extra, note) => {
    const { result, output, followUp } = await runShape({ action: "run", command: "echo SHAPE_OK", ...extra });
    expect(result.code).toBe(0);
    expect(output.final_output).toBe("SHAPE_DONE");
    expect(output.tool_calls[0]!.status).toBe("success");
    expect(followUp).toContain("SHAPE_OK");
    expect(followUp).toContain(note);
  });

  test.each([
    ["explicit shell with tty=true", { shell: bash, tty: true }],
    ["explicit clean shell with tty=true", { shell: { ...bash, clean_start: true }, tty: true }],
    ["clean profile with tty=true", { profile: "clean", tty: true }],
  ])("%s runs without a note", async (_name, extra) => {
    const { output, followUp } = await runShape({ action: "run", command: "echo SHAPE_OK", ...extra });
    expect(output.tool_calls[0]!.status).toBe("success");
    expect(followUp).toContain("SHAPE_OK");
    expect(followUp).not.toContain("ignored because");
  });

  test.each([
    ["/bin/sh", "only bash and zsh are supported"],
    ["bash", "not an absolute path"],
    ["/nonexistent/bash", "no such file exists on this host"],
  ])("unusable shell path %s is a recoverable error that states the fix", async (path, reason) => {
    const { result, output, followUp } = await runShape({
      action: "run",
      command: "echo SHAPE_OK",
      shell: { kind: "executable", path },
      tty: true,
    });
    expect(result.code).toBe(0);
    expect(output.final_output).toBe("SHAPE_DONE");
    expect(output.tool_calls[0]!.status).toBe("error");
    expect(followUp).toContain(reason);
    expect(followUp).toContain("Omit request.shell to use the default shell");
  });

  test("an invalid request states the corrected call shape", async () => {
    const { output, followUp } = await runShape({ action: "run", background: true });
    expect(output.tool_calls[0]!.status).toBe("error");
    expect(followUp).toContain("invalid_shell_request");
    expect(followUp).toContain("omit shell and profile unless the user named a shell");
  });
});
