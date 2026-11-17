"""Brand migration checks with temporary plists and mocked system commands only."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("brand_migration", Path(__file__).parents[1] / "migrate-brand.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


@unittest.skipIf(sys.platform == "win32", "Mac migration uses POSIX paths; run these checks on macOS or Linux")
class BrandMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.app = self.home / "NoASR.app"
        contents = self.app / "Contents"
        contents.mkdir(parents=True)
        self.info = contents / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.daiwen.voice-input"}))
        self.startup = self.home / "Library/LaunchAgents/com.daiwen.voice-input.plist"
        self.calls = []
        self.imported = None
        self.dock = {"persistent-apps": []}

    def run_migration(self):
        def run(args, **kwargs):
            self.calls.append(args)
            if args[:3] == ["/usr/bin/defaults", "export", "com.apple.dock"]:
                return subprocess.CompletedProcess(args, 0, stdout=plistlib.dumps(self.dock))
            if args[:3] == ["/usr/bin/defaults", "import", "com.apple.dock"]:
                self.imported = plistlib.loads(Path(args[3]).read_bytes())
            return subprocess.CompletedProcess(args, 0)
        with patch.object(migration.Path, "home", return_value=self.home), \
             patch.object(migration.subprocess, "run", side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            migration.main(str(self.app))

    def test_migrates_only_legacy_references_and_preserves_other_settings(self):
        unrelated = {"tile-data": {"file-data": {"_CFURLString": "file:///Applications/Other.app/"},
                                    "file-label": "Other", "book": b"keep"}}
        self.dock["persistent-apps"] = [unrelated, {"tile-data": {
            "file-data": {"_CFURLString": "file:///Applications/OneMore.app/", "_CFURLStringType": 15},
            "file-label": "OneMore", "book": b"old"}}]
        self.startup.parent.mkdir(parents=True)
        original = {"Label": "com.daiwen.voice-input", "RunAtLoad": True,
                    "ProgramArguments": ["/usr/bin/open", "-g", "/Applications/OneMore.app"]}
        self.startup.write_bytes(plistlib.dumps(original))
        self.run_migration()
        self.assertEqual(self.imported["persistent-apps"][0], unrelated)
        changed = self.imported["persistent-apps"][1]["tile-data"]
        self.assertEqual(changed["file-data"]["_CFURLString"], self.app.as_uri() + "/")
        self.assertEqual(changed["file-label"], "NoASR")
        self.assertNotIn("book", changed)
        original["ProgramArguments"][-1] = str(self.app)
        self.assertEqual(plistlib.loads(self.startup.read_bytes()), original)

    def test_unrelated_dock_is_unchanged_and_disabled_autostart_is_not_created(self):
        self.dock["persistent-apps"] = [{"tile-data": {"file-data": {"_CFURLString": "file:///Applications/Other.app/"}}}]
        self.run_migration()
        self.assertIsNone(self.imported)
        self.assertFalse(self.startup.exists())
        self.assertEqual(len(self.calls), 1)

    def test_rejects_unexpected_destination_before_system_changes(self):
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.other.app"}))
        with self.assertRaises(ValueError):
            self.run_migration()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
