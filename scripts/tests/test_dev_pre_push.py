import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[1] / "dev-pre-push.sh"
ZERO = "0" * 40


class PrePushTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fx-pre-push-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), PATH=f"{self.bin}:{os.environ['PATH']}",
                        SCAN_LOG=str(self.root / "scan.jsonl"), FMT_LOG=str(self.root / "fmt.jsonl"))
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.com")
        self.git("remote", "add", "origin", str(self.root / "remote"))
        (self.root / "src").mkdir()
        (self.root / "src/old.zig").write_text("const old = 1;\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        (self.root / "src/new file.zig").write_text("const new = 2;\n")
        self.git("add", "src/new file.zig")
        self.git("commit", "-qm", "new source")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.executable("gitleaks", "import json,os,sys\nwith open(os.environ['SCAN_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nsys.exit(int(os.environ.get('SCAN_FAIL','0')))\n")
        self.executable("zig", "import json,os,sys\nfrom pathlib import Path\nwith open(os.environ['FMT_LOG'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nassert len(sys.argv)==3 and sys.argv[1]=='fmt'\nif os.environ.get('FMT_FAIL'): sys.exit(1)\nif os.environ.get('REFORMAT'): p=Path(sys.argv[2]); p.write_text(p.read_text()+'\\n'); print(p)\n")
        self.env["ZIG"] = str(self.bin / "zig")

    def git(self, *arguments):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *arguments],
                                       cwd=self.root, env=self.env, text=True)

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def run_hook(self, remote=ZERO, local=None, **environment):
        return subprocess.run(["bash", str(HOOK), "origin"], cwd=self.root,
                              env=dict(self.env, **environment), text=True, capture_output=True,
                              input=f"refs/heads/feature {local or self.head} refs/heads/feature {remote}\n", timeout=15)

    def scans(self):
        path = self.root / "scan.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_new_branch_keeps_one_range_and_formats_only_pushed_paths(self):
        old = self.root / "src/old.zig"
        old.write_text("unrelated uncommitted work\n")
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.scans(), [["git", f"--log-opts={self.head} --not --remotes=origin", "--redact", "--no-banner", "."]])
        self.assertEqual(json.loads((self.root / "fmt.jsonl").read_text()), ["fmt", "src/new file.zig"])
        self.assertEqual(old.read_text(), "unrelated uncommitted work\n")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")

    def test_existing_branch_uses_its_remote_base(self):
        result = self.run_hook(remote=self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.scans()[0][1], f"--log-opts={self.base}..{self.head}")

    def test_multiple_new_commits_keep_all_source_paths(self):
        (self.root / "src/second.zig").write_text("const second = 3;\n")
        self.git("add", "src/second.zig")
        self.git("commit", "-qm", "second source")
        self.head = self.git("rev-parse", "HEAD").strip()
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        formatted = [json.loads(line)[1] for line in (self.root / "fmt.jsonl").read_text().splitlines()]
        self.assertEqual(set(formatted), {"src/new file.zig", "src/second.zig"})

    def test_secret_scan_failure_blocks_push(self):
        self.assertNotEqual(self.run_hook(SCAN_FAIL="1").returncode, 0)

    def test_formatter_failure_blocks_push(self):
        self.assertNotEqual(self.run_hook(FMT_FAIL="1").returncode, 0)
        self.assertEqual(self.scans(), [])

    def test_format_changes_are_staged_and_block_push(self):
        self.assertNotEqual(self.run_hook(REFORMAT="1").returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "src/new file.zig\n")
        self.assertEqual(self.scans(), [])

    def test_branch_deletion_does_not_scan_or_format(self):
        result = self.run_hook(local=ZERO)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.scans(), [])
        self.assertFalse((self.root / "fmt.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
