"""只使用临时数据；不加载设备、热键或界面，不注入文字。
运行：python -m unittest discover -s windows/tests
"""
import ast
import importlib.util
import json
import logging
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

WINDOWS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("history_test_config", WINDOWS / "config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

# 直接执行源码中的结果保存方法；隔离 Windows 设备、UIA 和全局输入依赖。
engine_tree = ast.parse((WINDOWS / "engine.py").read_text(encoding="utf-8"))
engine_class = next(n for n in engine_tree.body if isinstance(n, ast.ClassDef) and n.name == "Engine")
save_node = next(n for n in engine_class.body if isinstance(n, ast.FunctionDef) and n.name == "_save_result")
namespace = {"config": config, "log": logging.getLogger(__name__)}
exec(compile(ast.Module(body=[save_node], type_ignores=[]), str(WINDOWS / "engine.py"), "exec"), namespace)
save_result = namespace["_save_result"]


class HistoryStorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.recordings = self.root / "recordings"
        self.history = self.root / "history.json"
        self.settings = self.root / "config.json"
        for name, value in [("CONFIG_PATH", self.settings), ("HISTORY_PATH", self.history),
                            ("RECORDINGS_DIR", self.recordings)]:
            patcher = patch.object(config, name, str(value))
            patcher.start()
            self.addCleanup(patcher.stop)

    def populate(self):
        self.recordings.mkdir()
        (self.recordings / "ordinary.wav").write_bytes(b"test audio")
        (self.recordings / "screenshot.jpg").write_bytes(b"test screenshot")
        training = self.recordings / "training"
        training.mkdir()
        (training / "old.flac").write_bytes(b"old training")
        (training / "index.jsonl").write_text('{"text":"test fixture"}\n', encoding="utf-8")
        (training / "nested").mkdir()
        (training / "nested" / "older.flac").write_bytes(b"old nested training")
        self.history.write_text('[{"id":"old","audio":"ordinary.wav"}]', encoding="utf-8")
        return training

    def test_clear_removes_old_training_audio_index_and_history(self):
        training = self.populate()
        config.clear_history()
        self.assertFalse(training.exists())
        self.assertFalse(self.history.exists())
        self.assertEqual(list(self.recordings.iterdir()), [])

    def test_clear_preserves_other_directories_and_configuration(self):
        self.populate()
        other = self.recordings / "personal-backup"
        other.mkdir()
        protected = other / "keep.txt"
        protected.write_text("keep", encoding="utf-8")
        self.settings.write_text('{"provider":"bailian"}', encoding="utf-8")
        config.clear_history()
        self.assertEqual(protected.read_text(), "keep")
        self.assertTrue(self.settings.exists())

    def test_clear_is_repeatable_with_missing_directories(self):
        config.clear_history()
        self.populate()
        config.clear_history()
        config.clear_history()

    def test_deletion_failure_is_reported_and_history_index_remains(self):
        self.populate()
        with patch.object(config.shutil, "rmtree", side_effect=PermissionError("test locked file")):
            with self.assertRaises(PermissionError):
                config.clear_history()
        self.assertTrue(self.history.exists())
        config.clear_history()
        self.assertFalse(self.history.exists())

    def test_training_symlink_does_not_delete_external_files(self):
        self.recordings.mkdir()
        external = self.root / "external"
        external.mkdir()
        protected = external / "keep.flac"
        protected.write_bytes(b"keep")
        link = self.recordings / "training"
        try:
            link.symlink_to(external, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("当前系统不允许创建测试符号链接")
        config.clear_history()
        self.assertFalse(link.is_symlink())
        self.assertEqual(protected.read_bytes(), b"keep")

    def test_old_training_switch_is_discarded_without_deleting_data(self):
        training = self.populate()
        for old_value in (True, False):
            with self.subTest(old_value=old_value):
                self.settings.write_text(json.dumps({"keep_training_audio": old_value}), encoding="utf-8")
                cfg = config.load_config()
                self.assertNotIn("keep_training_audio", cfg)
                config.save_config(cfg)
                self.assertNotIn("keep_training_audio", json.loads(self.settings.read_text()))
                self.assertTrue((training / "old.flac").exists())
        self.settings.unlink()
        self.assertNotIn("keep_training_audio", config.load_config())

    def test_disabled_history_result_does_not_create_media_or_index(self):
        engine = SimpleNamespace(result=Mock())
        save_result(engine, False, {"id": "test"}, text="test fixture", status="ok")
        engine.result.emit.assert_called_once_with("test fixture")
        self.assertFalse(self.recordings.exists())
        self.assertFalse(self.history.exists())

    def test_enabled_history_result_updates_normal_history_only(self):
        self.recordings.mkdir()
        entry = config.new_history_entry("test", audio="ordinary.wav")
        config.add_history(entry)
        engine = SimpleNamespace(result=Mock())
        save_result(engine, True, entry, text="test fixture", status="ok")
        self.assertEqual(config.load_history()[0]["text"], "test fixture")
        self.assertFalse((self.recordings / "training").exists())


if __name__ == "__main__":
    unittest.main()
