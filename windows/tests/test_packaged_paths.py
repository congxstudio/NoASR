"""安装版路径与启动命令，不创建真实自启项或设备。"""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


class PackagedPathsTests(unittest.TestCase):
    def load_config(self, temp, frozen):
        spec = importlib.util.spec_from_file_location("packaging_test_config",
            Path(__file__).resolve().parents[1] / "config.py")
        module = importlib.util.module_from_spec(spec)
        with patch.object(sys, "frozen", frozen, create=True), \
                patch.dict("os.environ", {"LOCALAPPDATA": temp}), \
                patch.object(sys, "executable", str(Path(temp) / "Programs" / "OneMore.exe")):
            spec.loader.exec_module(module)
            command = module.launch_command()
        return module, command

    def test_packaged_data_is_separate_from_resources_and_executable(self):
        with tempfile.TemporaryDirectory() as temp:
            module, command = self.load_config(temp, True)
            self.assertEqual(module.BASE_DIR, str(Path(temp) / "OneMore"))
            self.assertTrue(Path(module.BASE_DIR).is_dir())
            self.assertNotEqual(module.BASE_DIR, module.SOURCE_DIR)
            self.assertEqual(command, (str(Path(temp) / "Programs" / "OneMore.exe"), "", str(Path(temp) / "Programs")))

    def test_source_keeps_existing_data_location_and_script_argument(self):
        with tempfile.TemporaryDirectory() as temp:
            module, command = self.load_config(temp, False)
            self.assertNotEqual(module.BASE_DIR, str(Path(temp) / "OneMore"))
            self.assertEqual(command[1], '"' + str(Path(module.BASE_DIR) / "main.pyw") + '"')
