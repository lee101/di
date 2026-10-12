import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import game_tasks


class GameTasksTests(unittest.TestCase):
    def test_binary_identity_tracks_content_not_only_path_or_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "fx"
            binary.write_bytes(b"first")
            first = game_tasks.binary_identity(binary)
            self.assertEqual(first["bytes"], 5)
            self.assertEqual(len(first["sha256"]), 64)
            self.assertEqual(game_tasks.binary_identity(binary), first)
            binary.write_bytes(b"other")
            self.assertNotEqual(game_tasks.binary_identity(binary), first)

    def test_provider_route_is_explicit_and_contains_no_credentials(self):
        settings = game_tasks.provider_settings("stealth/space-bunny-alpha", "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY")
        self.assertEqual(settings["provider"], "game-bench")
        provider = settings["providers"]["game-bench"]
        self.assertEqual(provider["auth"], {"type": "bearer", "env": "OPENROUTER_API_KEY"})
        self.assertEqual(provider["reviewer_model"], settings["model"])
        self.assertEqual(provider["base_url"], "https://openrouter.ai/api/v1")
        self.assertEqual(provider["reasoning_format"], "openrouter")
        self.assertEqual(provider["model_metadata"][settings["model"]]["reasoning_efforts"], ["low"])
        self.assertNotIn("fallback", settings)

    def test_default_effort_does_not_declare_a_named_provider_effort(self):
        settings = game_tasks.provider_settings("free", "https://example.com/v1", "TOKEN", "auto", "omit")
        provider = settings["providers"]["game-bench"]
        self.assertEqual(provider["reasoning_format"], "omit")
        self.assertEqual(provider["model_metadata"]["free"]["reasoning_efforts"], [])

    def test_io_sampling_parses_counters_and_tolerates_exit(self):
        with patch.object(Path, "read_text", return_value="write_bytes: 4096\nsyscw: 8\n"):
            self.assertEqual(game_tasks.read_io(123), {"write_bytes": 4096, "syscw": 8})
        with patch.object(Path, "read_text", side_effect=FileNotFoundError):
            self.assertEqual(game_tasks.read_io(123), {})
        with patch.object(Path, "read_text", return_value="not a counter"):
            self.assertEqual(game_tasks.read_io(123), {})

    def test_storage_measurement_excludes_external_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / "game.mjs").write_bytes(b"game")
            outside = root / "outside"
            outside.write_bytes(b"must not count")
            (workspace / "link").symlink_to(outside)
            self.assertEqual(game_tasks.tree_size(workspace), {"files": 1, "bytes": 4})


if __name__ == "__main__":
    unittest.main()
