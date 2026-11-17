"""可配置的系统截图快捷键转发,不处理或保存截图。"""
import ctypes
import logging
import os
import time
from ctypes import wintypes

from PySide6.QtCore import QAbstractNativeEventFilter, QObject, QTimer, Signal, Slot

from streaming_input import HotkeyHook
from shortcuts import parse_hotkey, overlaps

log = logging.getLogger("system_snip")
user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT]
user32.RegisterHotKey.restype = wintypes.BOOL
user32.UnregisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int]
user32.UnregisterHotKey.restype = wintypes.BOOL
WM_HOTKEY = 0x0312
HOTKEY_ID = 0x5649
MOD_ALT, MOD_SHIFT, MOD_WIN, MOD_NOREPEAT = 0x0001, 0x0004, 0x0008, 0x4000
MODIFIERS = {"ctrl": 0x0002, "alt": MOD_ALT, "windows": MOD_WIN, "shift": MOD_SHIFT}
KEYS = {"space": 0x20, "tab": 0x09, "enter": 0x0D, "backspace": 0x08,
        "delete": 0x2E, "insert": 0x2D, "home": 0x24, "end": 0x23,
        "page up": 0x21, "page down": 0x22, "left": 0x25, "up": 0x26,
        "right": 0x27, "down": 0x28, "print screen": 0x2C}


def parse_shortcut(text):
    """截图组合键不区分左右修饰键,返回规范名字、修饰键位和普通键 VK。"""
    canonical, _groups = parse_hotkey(text, combined=True, sided=False)
    parts = canonical.split("+")
    mods = {p for p in parts if p in MODIFIERS}
    keys = [p for p in parts if p not in MODIFIERS]
    key = keys[0]
    if len(key) == 1 and key.isascii() and key.isalnum():
        vk = ord(key.upper())
    elif key.startswith("f") and key[1:].isdigit() and 1 <= int(key[1:]) <= 24:
        vk = 0x70 + int(key[1:]) - 1
    elif key in KEYS:
        vk = KEYS[key]
    else:
        import keyboard
        if key == "plus":
            vk = user32.VkKeyScanW(ord("+")) & 0xFF
        elif len(key) == 1:
            vk = user32.VkKeyScanW(ord(key)) & 0xFF
        else:
            scan = keyboard.key_to_scan_codes(key)[0]
            vk = -scan if scan < 0 else user32.MapVirtualKeyW(scan, 3)
        if vk == 0xFF:
            vk = 0  # 没有可注册的 VK 时改用按键钩子。
    name = "+".join([m for m in MODIFIERS if m in mods] + [key])
    if name in ("ctrl+alt+delete", "windows+l"):
        raise ValueError("这个组合键由系统保留，请换一个")
    return name, sum(MODIFIERS[m] for m in mods), vk


def shortcut_name(text):
    try:
        return parse_shortcut(text)[0]
    except ValueError:
        return text.strip().lower()


class _HookRelay(QObject):
    """把钩子工作线程的通知排到界面线程,不在后台线程操作 QTimer。"""
    requested = Signal(str)

    def __init__(self, callback, parent):
        super().__init__(parent)
        self.callback = callback
        self.requested.connect(self.dispatch)

    @Slot(str)
    def dispatch(self, label):
        self.callback(label)


class SystemSnip(QAbstractNativeEventFilter):
    def __init__(self, app, on_error):
        super().__init__()
        self.app = app
        self.on_error = on_error
        self._registered = {}
        self._fallback = {}
        self._bindings = {}
        self._settings = None
        self._suspended = False
        self.errors = []
        self._relay = _HookRelay(self._request_capture, app)
        self._timer = QTimer(app)
        self._timer.setInterval(25)
        self._timer.timeout.connect(self._wait_release)

    def apply(self, cfg):
        settings = (bool(cfg.get("screenshot_tool_enabled", False)),
                    tuple(cfg.get("screenshot_hotkeys", ["alt+shift+a", "windows+shift+a"])),
                    cfg.get("hotkey", ""), cfg.get("dictionary_hotkey", ""))
        if settings == self._settings:
            return
        self.stop()
        self._settings = settings
        self.errors = []
        self.start()

    def suspend(self):
        self._suspended = True
        self.stop()

    def resume(self):
        self._suspended = False
        self.start()

    def _error(self, message):
        self.errors.append(message)
        self.on_error(message)

    def start(self):
        if self._registered or self._fallback:
            return
        if self._suspended or not self._settings or not self._settings[0]:
            return
        self.errors = []
        _enabled, shortcuts, voice, dictionary = self._settings
        for index, text in enumerate(shortcuts):
            try:
                label, modifiers, vk = parse_shortcut(text)
            except ValueError as e:
                self._error(f"截图快捷键 {index + 1}：{e}")
                continue
            if label in self._bindings:
                continue
            if overlaps(label, voice) or overlaps(label, dictionary):
                self._error(f"截图快捷键 {index + 1} 与录音或词典快捷键重复")
                continue
            hotkey_id = HOTKEY_ID + index
            if not vk or not user32.RegisterHotKey(None, hotkey_id, modifiers | MOD_NOREPEAT, vk):
                code = ctypes.get_last_error() if vk else 1409
                log.warning("系统截图快捷键 %s 注册失败: winerror=%d", label, code)
                if code == 1409:
                    try:
                        self._fallback[label] = HotkeyHook(label, lambda k=label: self._fallback_trigger(k))
                        self._bindings[label] = vk
                        log.info("系统截图快捷键 %s 已改用独立按键钩子", label)
                        continue
                    except Exception:
                        log.exception("系统截图快捷键 %s 备用钩子启动失败", label)
                self._error(f"截图快捷键 {index + 1} 注册失败")
                continue  # 一个被占用不影响另一个。
            self._registered[hotkey_id] = label
            self._bindings[label] = vk
            log.info("系统截图快捷键已注册: %s", label)
        if self._registered:
            self.app.installNativeEventFilter(self)

    def nativeEventFilter(self, event_type, message):
        if event_type in (b"windows_dispatcher_MSG", b"windows_generic_MSG") and self._registered:
            msg = wintypes.MSG.from_address(int(message))
            if msg.message == WM_HOTKEY and msg.wParam in self._registered:
                self._request_capture(self._registered[msg.wParam])
                return True, 0
        return False, 0

    def _fallback_trigger(self, label):
        # 触发键被拦下后插一个无效按键,避免松开 Alt/Win 时误弹菜单。
        from engine import cancel_menu_activation
        cancel_menu_activation()
        self._relay.requested.emit(label)

    def _request_capture(self, label):
        if label not in self._bindings or self._timer.isActive():
            return
        log.info("系统截图快捷键 %s 触发,等待松键", label)
        self._deadline = time.monotonic() + 3.0
        self._trigger_vk = self._bindings[label]
        self._timer.start()

    def _wait_release(self):
        # 不补发修饰键,避免 Alt 卡住;等松键后再打开系统框选界面。
        if any(user32.GetAsyncKeyState(vk) & 0x8000 for vk in (0x11, 0x12, 0x10, 0x5B, 0x5C, self._trigger_vk)):
            if time.monotonic() >= self._deadline:
                self._timer.stop()
                log.info("系统截图快捷键等待松键超时,取消本次截图")
            return
        self._timer.stop()
        # 使用本机已实测的系统交互截图入口,由系统管理标记和剪贴板。
        # capture/image 新协议要求 MSIX 身份和回调,不适用于本程序。
        try:
            os.startfile("ms-screenclip:")
            log.info("已调用 Windows 系统截图工具")
        except OSError:
            log.exception("Windows 系统截图工具启动失败")
            self._error("系统截图工具启动失败，请用 Win+Shift+S 检查是否能正常截图")

    def stop(self):
        if self._fallback:
            for hook in self._fallback.values():
                hook.stop()
            self._fallback.clear()
        self._bindings.clear()
        self._timer.stop()
        if self._registered:
            for hotkey_id in self._registered:
                user32.UnregisterHotKey(None, hotkey_id)
            self.app.removeNativeEventFilter(self)
            self._registered.clear()
