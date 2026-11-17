"""Installer-only compatibility work; never reads app settings, history or recordings."""
import os
from pathlib import Path
import re
import sys

LEGACY_UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{B9866D08-10BD-4B43-A98D-F0EE5021C620}_is1"
TASK_NAME = "DaiwenVoiceInput"


def normalized(path):
    return os.path.normcase(os.path.realpath(os.path.expandvars(str(path).strip('"'))))


def cleanup_autostart(executable, service):
    service.Connect()
    folder = service.GetFolder("\\")
    try:
        task = folder.GetTask(TASK_NAME)
    except Exception as error:
        if getattr(error, "hresult", 0) & 0xffffffff in (0x80070002, 0x8004130f):
            return
        raise
    actions = task.Definition.Actions
    if actions.Count != 1:
        return
    action = actions.Item(1)
    if action.Type != 0 or not os.path.isabs(str(action.Path).strip('"')):
        return
    if normalized(action.Path) == normalized(executable):
        folder.DeleteTask(TASK_NAME, 0)


def migrate_inno(executable, registry):
    try:
        with registry.OpenKey(registry.HKEY_CURRENT_USER, LEGACY_UNINSTALL_KEY) as key:
            location = registry.QueryValueEx(key, "InstallLocation")[0]
            uninstall = registry.QueryValueEx(key, "UninstallString")[0]
    except FileNotFoundError:
        return
    install_dir = Path(executable).resolve().parent
    if normalized(location) != normalized(install_dir):
        return
    uninstaller = Path(str(uninstall).strip().strip('"'))
    if (normalized(uninstaller.parent) != normalized(install_dir)
            or not re.fullmatch(r"unins\d{3}\.exe", uninstaller.name, re.IGNORECASE)):
        return
    # Delete only the explicitly registered legacy uninstaller, never execute it.
    for suffix in (".exe", ".dat", ".msg"):
        path = uninstaller.with_suffix(suffix)
        if path.exists():
            path.unlink()
    registry.DeleteKey(registry.HKEY_CURRENT_USER, LEGACY_UNINSTALL_KEY)


def run(mode):
    if not getattr(sys, "frozen", False):
        return 1
    try:
        if mode == "--installer-migrate":
            import winreg
            migrate_inno(sys.executable, winreg)
        else:
            import comtypes.client
            service = comtypes.client.CreateObject("Schedule.Service", dynamic=True)
            cleanup_autostart(sys.executable, service)
        return 0
    except Exception:
        return 1
