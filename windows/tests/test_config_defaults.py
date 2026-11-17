"""仅使用临时配置，检查新安装与旧设置兼容，不启动应用、设备或网络。"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "defaults_test_config", Path(__file__).resolve().parents[1] / "config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ConfigDefaultsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "config.json"
        for patcher in (patch.object(config, "CONFIG_PATH", str(self.path)),
                        patch.dict(os.environ, {}, clear=True)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_fresh_install_and_missing_fields_use_new_defaults(self):
        for content in (None, {}, {"appearance": "dark"}):
            if content is not None:
                self.path.write_text(json.dumps(content), encoding="utf-8")
            cfg = config.load_config()
            self.assertEqual(list(config.PROVIDERS), ["volcano", "bailian_cn", "mimo", "gemini"])
            self.assertEqual(cfg["provider"], "volcano")
            self.assertTrue(cfg["volcano_fast"])
            self.assertTrue(cfg["autostart"])
            self.assertTrue(cfg["strip_trailing_punct"])
            self.assertFalse(cfg["screenshot_tool_enabled"])
            self.assertEqual(cfg["sound_style"], "bubble")
            self.assertTrue(all(not p["api_key"] for p in cfg["providers"].values()))

    def test_saved_choices_are_preserved(self):
        saved = dict(provider="mimo", volcano_fast=False, autostart=False,
                     strip_trailing_punct=False, screenshot_tool_enabled=True, sound_style="bell")
        self.path.write_text(json.dumps(saved), encoding="utf-8")
        cfg = config.load_config()
        for key, value in saved.items():
            self.assertEqual(cfg[key], value)

    def test_removed_provider_and_bridge_do_not_return_on_save(self):
        saved = dict(provider="bailian", providers={"bailian": {"api_key": "fixture-only"}},
                     api_key="legacy-fixture-only", asr_bridge_token="fixture-token", asr_bridge_port=8095)
        self.path.write_text(json.dumps(saved), encoding="utf-8")
        cfg = config.load_config()
        config.save_config(cfg)
        restored = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(restored["provider"], "volcano")
        self.assertNotIn("bailian", restored["providers"])
        for key in ("api_key", "asr_bridge_token", "asr_bridge_port"):
            self.assertNotIn(key, restored)
        self.assertTrue(all(not p["api_key"] for p in restored["providers"].values()))

    def test_environment_key_is_loaded_without_a_saved_config(self):
        with patch.dict(os.environ, {"ARK_API_KEY": "fixture-env-only"}):
            self.assertEqual(config.load_config()["providers"]["volcano"]["api_key"], "fixture-env-only")
