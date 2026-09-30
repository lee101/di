import { afterEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const roots: string[] = [];
afterEach(() => {
  while (roots.length) rmSync(roots.pop()!, { recursive: true, force: true });
});

function fixture() {
  const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-storage-")));
  roots.push(home);
  const fx = join(home, ".fx");
  const results = join(fx, "sessions", "cold1", "tool-results");
  mkdirSync(results, { recursive: true, mode: 0o700 });
  mkdirSync(join(fx, "file-index"), { mode: 0o700 });
  writeFileSync(join(fx, "sessions", "cold1", "events.jsonl"), "{}\n", { mode: 0o600 });
  const body = Array.from({ length: 3000 }, (_, i) => `row ${i % 40} of a repetitive tool result`).join("\n");
  writeFileSync(join(results, "result-1.txt"), body, { mode: 0o600 });
  const entries = Array.from({ length: 4000 }, (_, i) => ({ path: `src/pkg${i % 20}/file${i}.zig`, kind: 0 }));
  const payload = JSON.stringify({ written_at_ms: 1, roots: ["/w"], entries });
  const digest = createHash("sha256").update(payload).digest();
  const idx = join(fx, "file-index", "abc.idx");
  writeFileSync(idx, Buffer.concat([Buffer.from("fx-file-index-v1\n"), digest, Buffer.from(payload)]), { mode: 0o600 });
  return { home, fx, results, idx, body, idxSize: readFileSync(idx).length };
}

const run = (home: string, ...args: string[]) => runFx(["storage", ...args], { env: { HOME: home }, timeoutMs: 20_000 });

describe("di storage", () => {
  test("stats, compact, lazy restore keep data intact", async () => {
    const f = fixture();
    const stats = await run(f.home, "stats");
    expect(stats.code).toBe(0);
    expect(stats.stdout).toContain("sessions 1");
    expect(stats.stdout).toContain("1 legacy");

    const dry = await run(f.home, "compact", "--older-than", "0", "--dry-run");
    expect(dry.stdout).toContain("dry-run");
    expect(existsSync(join(f.results, "result-1.txt"))).toBe(true);

    const compact = await run(f.home, "compact", "--older-than", "0");
    expect(compact.code).toBe(0);
    expect(existsSync(join(f.results, "result-1.txt"))).toBe(false);
    expect(existsSync(join(f.results, "result-1.txt.fxz"))).toBe(true);
    expect(readFileSync(f.idx).subarray(0, 16).toString()).toBe("fx-file-index-v2");
    expect(readFileSync(f.idx).length * 4).toBeLessThan(f.idxSize);

    const restore = await run(f.home, "restore");
    expect(restore.stdout).toContain("restored 1 files");
    expect(readFileSync(join(f.results, "result-1.txt"), "utf8")).toBe(f.body);
    expect(existsSync(join(f.results, "result-1.txt.fxz"))).toBe(false);
  }, 60_000);

  test("rejects unknown arguments", async () => {
    const f = fixture();
    const r = await run(f.home, "bogus");
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("usage: di storage");
  }, 20_000);
});
