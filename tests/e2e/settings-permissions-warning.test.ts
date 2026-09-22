import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TMUX_SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function flatten(text: string): string {
  return text.replace(/\s+/g, "");
}

describe.skipIf(TMUX_SKIP)("tui: settings permission notice", () => {
  test(
    "loose settings modes surface the permission-rules warning at startup",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-settings-permissions-"));
      tempDirs.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const fxDir = join(home, ".fx");
      mkdirSync(fxDir, { recursive: true, mode: 0o700 });
      chmodSync(fxDir, 0o700);
      mkdirSync(workspace, { recursive: true });
      const settingsPath = join(fxDir, "settings.json");
      writeFileSync(
        settingsPath,
        JSON.stringify({ permission: { web_search: { "*": "deny" } } }),
        { mode: 0o600 },
      );
      // Group-writable settings.json is rejected as private state; the user
      // layer degrades and the startup notice must say so.
      chmodSync(settingsPath, 0o664);

      const terminal = await TmuxSession.create({
        cwd: workspace,
        stderrPath: join(root, "stderr.log"),
        isolated: true,
        env: {
          HOME: home,
          FX_SOUND: "0",
          AI_GATEWAY_API_KEY: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          VERCEL_OIDC_TOKEN: undefined,
        },
      });
      session = terminal;
      await terminal.waitForComposer(15_000);
      await terminal.waitForPane(
        (pane) => flatten(pane).includes(flatten("1 configuration issue")),
        15_000,
      );
      await terminal.sendKeys("C-o");
      const detail = await terminal.waitForPane(
        (pane) =>
          flatten(pane).includes(
            flatten("configured permission rules are NOT being applied"),
          ),
        15_000,
      );
      const flatDetail = flatten(detail);
      expect(flatDetail).toContain(flatten(`${settingsPath} has mode 0664`));
      expect(flatDetail).toContain("0700");
      expect(flatDetail).toContain("0600");
    },
    TIMEOUT,
  );
});
