"""Installer ownership decisions use temporary files and fake registry/tasks only."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location("installer_hooks", Path(__file__).parents[1] / "installer_hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)


class InstallerHooksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.exe = self.folder / "NoASR.exe"
        self.service = Mock()
        self.tasks = self.service.GetFolder.return_value
        self.actions = self.tasks.GetTask.return_value.Definition.Actions
        self.actions.Count = 1
        self.actions.Item.return_value = SimpleNamespace(Type=0, Path=str(self.exe))

    def test_removes_only_task_owned_by_installed_executable(self):
        hooks.cleanup_autostart(str(self.exe), self.service)
        self.tasks.DeleteTask.assert_called_once_with(hooks.TASK_NAME, 0)

    def test_source_or_other_installation_task_is_retained(self):
        self.actions.Item.return_value.Path = str(self.folder / "pythonw.exe")
        hooks.cleanup_autostart(str(self.exe), self.service)
        self.tasks.DeleteTask.assert_not_called()

    def test_multiple_actions_are_retained(self):
        self.actions.Count = 2
        hooks.cleanup_autostart(str(self.exe), self.service)
        self.tasks.DeleteTask.assert_not_called()

    def test_absent_task_does_not_fail_uninstall(self):
        error = OSError("missing")
        error.hresult = -2147024894
        self.tasks.GetTask.side_effect = error
        hooks.cleanup_autostart(str(self.exe), self.service)
        self.tasks.DeleteTask.assert_not_called()

    def fake_registry(self, location):
        key = Mock()
        registry = Mock(HKEY_CURRENT_USER="current-user")
        registry.OpenKey.return_value.__enter__ = Mock(return_value=key)
        registry.OpenKey.return_value.__exit__ = Mock(return_value=False)
        values = {"InstallLocation": str(location),
                  "UninstallString": '"' + str(location / "unins000.exe") + '"'}
        registry.QueryValueEx.side_effect = lambda key, name: (values[name], 1)
        return registry

    def test_legacy_migration_removes_only_registered_uninstaller_files(self):
        registry = self.fake_registry(self.folder)
        for suffix in ("exe", "dat", "msg"):
            (self.folder / ("unins000." + suffix)).write_text("legacy", encoding="utf-8")
        unrelated = self.folder / "keep.txt"
        unrelated.write_text("keep", encoding="utf-8")
        hooks.migrate_inno(str(self.exe), registry)
        self.assertTrue(unrelated.exists())
        self.assertFalse((self.folder / "unins000.exe").exists())
        registry.DeleteKey.assert_called_once_with("current-user", hooks.LEGACY_UNINSTALL_KEY)

    def test_legacy_record_of_another_installation_is_retained(self):
        other = self.folder / "other"
        registry = self.fake_registry(other)
        hooks.migrate_inno(str(self.exe), registry)
        registry.DeleteKey.assert_not_called()

    def test_source_entrypoint_cannot_execute_installer_hooks(self):
        self.assertEqual(hooks.run("--uninstall-cleanup"), 1)


if __name__ == "__main__":
    unittest.main()
