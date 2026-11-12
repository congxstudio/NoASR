"""流式回填:识别结果边收边打字到录音开始时的输入位置。规则与 macos/Sources/StreamingInput.swift 对齐。

- 录音开始时记住目标(前台窗口 + 焦点控件窗口),每批写入前核对,不一致就停。
- 回填期间用户真实地按键、按鼠标、切换窗口 → 立即停止(自己用 SendInput 注入的事件带"注入"标记,不算)。
- 停止后完整结果保留在历史;若识别完整成功但没打完,自动复制全文到剪贴板。
- 不读取输入框里已有的文字。
"""
import ctypes
import logging
import queue
import struct
import threading
import time
import unicodedata
from ctypes import wintypes

import keyboard
from shortcuts import parse_hotkey
from password_guard import focused_is_password

log = logging.getLogger("input")
user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

BATCH_UNITS = 20  # 每次 SendInput 最多发送的 UTF-16 单元数

_INPUT_KEYBOARD = 1
_KEYEVENTF_KEYUP = 0x0002
_KEYEVENTF_UNICODE = 0x0004
_VK_RETURN = 0x0D
_VK_SHIFT = 0x10


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("ki", _KEYBDINPUT), ("mi", _MOUSEINPUT)]
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]


def send_inputs(inputs):
    arr = (_INPUT * len(inputs))(*inputs)
    user32.SendInput(len(inputs), arr, ctypes.sizeof(_INPUT))


def key_input(vk=0, scan=0, flags=0):
    return _INPUT(type=_INPUT_KEYBOARD, ki=_KEYBDINPUT(vk, scan, flags, 0, 0))


def press_enter():
    send_inputs([key_input(vk=_VK_RETURN), key_input(vk=_VK_RETURN, flags=_KEYEVENTF_KEYUP)])


def _newline():
    # 换行用 Shift+回车:聊天软件里单独回车是"发送",会把长文拆成多条消息
    send_inputs([key_input(vk=_VK_SHIFT), key_input(vk=_VK_RETURN),
                 key_input(vk=_VK_RETURN, flags=_KEYEVENTF_KEYUP),
                 key_input(vk=_VK_SHIFT, flags=_KEYEVENTF_KEYUP)])


def _type_units(units):
    events = []
    for u in units:
        events.append(key_input(scan=u, flags=_KEYEVENTF_UNICODE))
        events.append(key_input(scan=u, flags=_KEYEVENTF_UNICODE | _KEYEVENTF_KEYUP))
    send_inputs(events)


def type_text(text, can_write=lambda: True):
    """用 SendInput Unicode 小批量输入,不经过剪贴板。can_write() 返回 False 时停止并返回 False。"""
    for i, line in enumerate(text.replace("\r\n", "\n").split("\n")):
        if i:
            if not can_write():
                return False
            _newline()
            time.sleep(0.01)
        data = line.encode("utf-16-le")
        units = struct.unpack(f"<{len(data) // 2}H", data)
        pos = 0
        while pos < len(units):
            end = min(len(units), pos + BATCH_UNITS)
            if end < len(units) and 0xD800 <= units[end - 1] <= 0xDBFF:
                end += 1  # 不把一个 emoji 的代理对拆到两批
            if not can_write():
                return False
            _type_units(units[pos:end])
            pos = end
    return True


def wait_modifiers_released(timeout=3.0):
    """组合键还按着时输入会变成快捷键,先等修饰键都松开。"""
    end = time.time() + timeout
    while time.time() < end and any(
            keyboard.is_pressed(k) for k in ("ctrl", "shift", "alt", "windows")):
        time.sleep(0.02)


# ---------- 输入目标 ----------
class GUITHREADINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("hwndActive", wintypes.HWND), ("hwndFocus", wintypes.HWND),
                ("hwndCapture", wintypes.HWND), ("hwndMenuOwner", wintypes.HWND),
                ("hwndMoveSize", wintypes.HWND), ("hwndCaret", wintypes.HWND),
                ("rcCaret", wintypes.RECT)]


def _focus_of(hwnd):
    tid = user32.GetWindowThreadProcessId(hwnd, None)
    info = GUITHREADINFO(cbSize=ctypes.sizeof(GUITHREADINFO))
    if tid and user32.GetGUIThreadInfo(tid, ctypes.byref(info)):
        return info.hwndFocus or None
    return None


class Destination:
    """录音开始时的输入目标:前台窗口 + 其中有焦点的控件窗口。"""

    def __init__(self, hwnd, focus):
        self.hwnd, self.focus = hwnd, focus

    @classmethod
    def capture(cls):
        if focused_is_password():
            return None
        hwnd = user32.GetForegroundWindow()
        return cls(hwnd, _focus_of(hwnd)) if hwnd else None

    @property
    def chromium(self):
        """Chromium/Electron 内核窗口(Claude、Codex、Obsidian、Chrome、Edge…):模拟输入偶尔丢最后一批字,回填后要读回校验。"""
        buf = ctypes.create_unicode_buffer(64)
        user32.GetClassNameW(self.hwnd, buf, 64)
        return buf.value == "Chrome_WidgetWin_1"

    def is_current(self):
        if focused_is_password():
            return False
        hwnd = user32.GetForegroundWindow()
        if hwnd != self.hwnd:
            return False
        # 取不到焦点控件的程序只核对前台窗口,另由操作监听防止误输入
        return self.focus is None or _focus_of(hwnd) == self.focus


# ---------- 用户操作监听 ----------
WH_KEYBOARD_LL, WH_MOUSE_LL = 13, 14
WM_KEYDOWN, WM_SYSKEYDOWN = 0x0100, 0x0104
WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN = 0x0201, 0x0204, 0x0207, 0x020B
LLKHF_INJECTED, LLMHF_INJECTED = 0x10, 0x01
# 单独按修饰键不会输入内容(和 Mac 一致不算用户操作),也避免还按着热键时的自动重复误判
MODIFIER_VKS = {0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C}
WM_QUIT = 0x0012

HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = ctypes.c_ssize_t
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = wintypes.HHOOK


class _KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", wintypes.POINT), ("mouseData", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


_VK_CONTROL, _VK_MENU, _VK_LWIN, _VK_RWIN = 0x11, 0x12, 0x5B, 0x5C


class ActivityMonitor:
    """监听真实的按键/鼠标按下(自己注入的不算)。
    on_enter 给定时,会拦下单独按的回车(不带 Shift/Ctrl/Alt/Win)交给它处理,不再传给目标程序。"""

    def __init__(self, on_activity, on_enter=None):
        self._on_activity = on_activity
        self._on_enter = on_enter
        self._enter_blocked = False
        # 开始监听前就按着的键(如热键)松开前的自动重复不算
        self._held = {vk for vk in range(1, 256) if user32.GetAsyncKeyState(vk) & 0x8000}
        self._tid = None
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        self._ready.wait(1)

    def _run(self):
        self._tid = kernel32.GetCurrentThreadId()

        def kb(code, wparam, lparam):
            if code >= 0 and self._on_enter is not None:
                info = ctypes.cast(lparam, ctypes.POINTER(_KBDLLHOOKSTRUCT)).contents
                if info.vkCode == _VK_RETURN and not info.flags & LLKHF_INJECTED:
                    if wparam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                        plain = not any(user32.GetAsyncKeyState(vk) & 0x8000
                                        for vk in (_VK_SHIFT, _VK_CONTROL, _VK_MENU, _VK_LWIN, _VK_RWIN))
                        if plain:
                            self._enter_blocked = True
                            self._on_enter()
                            return 1  # 拦下,不让目标程序收到(否则会把半截内容发出去)
                    elif self._enter_blocked:
                        self._enter_blocked = False
                        return 1  # 对应的松开也拦下
            if code >= 0 and wparam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                info = ctypes.cast(lparam, ctypes.POINTER(_KBDLLHOOKSTRUCT)).contents
                real = not info.flags & LLKHF_INJECTED
                if real and info.vkCode not in MODIFIER_VKS and info.vkCode not in self._held:
                    self._on_activity("按键", info.scanCode, None)
            elif code >= 0:
                info = ctypes.cast(lparam, ctypes.POINTER(_KBDLLHOOKSTRUCT)).contents
                self._held.discard(info.vkCode)  # 松开后再按就算用户操作
            return user32.CallNextHookEx(None, code, wparam, lparam)

        def ms(code, wparam, lparam):
            if code >= 0 and wparam in (WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN):
                info = ctypes.cast(lparam, ctypes.POINTER(_MSLLHOOKSTRUCT)).contents
                if not info.flags & LLMHF_INJECTED:
                    button = {WM_LBUTTONDOWN: "左键", WM_RBUTTONDOWN: "右键", WM_MBUTTONDOWN: "中键",
                              WM_XBUTTONDOWN: "侧键"}[wparam]
                    self._on_activity(f"鼠标{button}", None, (info.pt.x, info.pt.y))
            return user32.CallNextHookEx(None, code, wparam, lparam)

        kb_proc, ms_proc = HOOKPROC(kb), HOOKPROC(ms)  # 保持引用,防止被回收
        hooks = [user32.SetWindowsHookExW(WH_KEYBOARD_LL, kb_proc, None, 0),
                 user32.SetWindowsHookExW(WH_MOUSE_LL, ms_proc, None, 0)]
        self._ready.set()
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            pass
        for h in hooks:
            if h:
                user32.UnhookWindowsHookEx(h)

    def stop(self):
        if self._tid:
            user32.PostThreadMessageW(self._tid, WM_QUIT, 0, 0)


class HotkeyHook:
    """全局组合键(如 ctrl+alt+x),用自己的低级键盘钩子:只拦最后那个触发键(连同它的松开),
    Ctrl/Alt/Shift/Win 原样放行、一个都不碰。
    不用 keyboard.add_hotkey(suppress=True):它会扣住每一次 Ctrl/Alt 再补发,补发出错时系统以为
    Alt 一直按着,整个键盘打不了字(2026-10-25 用户实际遇到)。"""
    MODS = {"ctrl": (0xA2, 0xA3), "alt": (0xA4, 0xA5), "shift": (0xA0, 0xA1), "windows": (0x5B, 0x5C)}

    def __init__(self, hotkey, on_trigger):
        self._on_trigger = on_trigger
        hotkey = parse_hotkey(hotkey, combined=True)[0]
        self._need = {}    # 修饰键 -> 必须按着的 VK 组,组内任一满足、组间全部满足。
        keys = []
        for part in (p.strip() for p in hotkey.lower().split("+") if p.strip()):
            side = part.split(" ", 1)[0] if part.startswith(("left ", "right ")) else ""
            base = part[len(side):].strip()
            if base in self.MODS:
                left, right = self.MODS[base]
                self._need.setdefault(base, []).append({"left": (left,), "right": (right,)}.get(side, (left, right)))
            else:
                keys.append(part)
        if len(keys) != 1 or not self._need:
            raise ValueError("需要至少一个修饰键加一个普通键,如 Ctrl+Alt+X")
        self._scans = set(keyboard.key_to_scan_codes(keys[0]))
        self._blocked = False
        self._tid = None
        ready = threading.Event()
        installed = []
        self._stopping = threading.Event()

        def run():
            self._tid = kernel32.GetCurrentThreadId()
            msg = wintypes.MSG()
            user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 0)  # 先建消息队列,确保 stop 能送达。

            def kb(code, wparam, lparam):
                if code >= 0:
                    info = ctypes.cast(lparam, ctypes.POINTER(_KBDLLHOOKSTRUCT)).contents
                    if (info.scanCode or -info.vkCode) in self._scans and not info.flags & LLKHF_INJECTED:
                        if wparam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                            if self._blocked:
                                return 1  # 按住时的自动重复不重复执行。
                            if self._matches():
                                self._blocked = True
                                threading.Thread(target=self._on_trigger, daemon=True).start()
                                return 1
                        elif self._blocked:
                            self._blocked = False
                            return 1
                return user32.CallNextHookEx(None, code, wparam, lparam)

            proc = HOOKPROC(kb)
            hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, proc, None, 0)
            installed.append(bool(hook))
            ready.set()
            while hook and not self._stopping.is_set() and user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                pass
            if hook:
                user32.UnhookWindowsHookEx(hook)

        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()
        if not ready.wait(2) or not installed or not installed[0]:
            self.stop()
            raise RuntimeError("系统未能启动快捷键监听，请重启程序后再试")

    def _matches(self):
        down = lambda vk: user32.GetAsyncKeyState(vk) & 0x8000
        for name, (left, right) in self.MODS.items():
            held = down(left) or down(right)
            if name in self._need:
                if not all(any(down(vk) for vk in group) for group in self._need[name]):
                    return False
            elif held:
                return False  # 多按了别的修饰键,不是这个组合
        return True

    def stop(self):
        self._stopping.set()
        if self._tid:
            user32.PostThreadMessageW(self._tid, WM_QUIT, 0, 0)
        if threading.current_thread() is not self._thread:
            self._thread.join(timeout=0.5)


class KeyInterceptor:
    """临时拦下真实按的 Ctrl+Enter(不带 Shift/Alt/Win)交给 on_trigger,不让目标程序收到。
    用于"记住 X?"询问胶囊:在 Claude、微信里 Ctrl+Enter 本身有功能,询问期间不能漏过去。"""

    def __init__(self, on_trigger):
        self._on_trigger = on_trigger
        self._blocked = False
        self._tid = None
        ready = threading.Event()

        def run():
            self._tid = kernel32.GetCurrentThreadId()

            def kb(code, wparam, lparam):
                if code >= 0:
                    info = ctypes.cast(lparam, ctypes.POINTER(_KBDLLHOOKSTRUCT)).contents
                    if info.vkCode == _VK_RETURN and not info.flags & LLKHF_INJECTED:
                        if wparam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                            down = lambda vk: user32.GetAsyncKeyState(vk) & 0x8000
                            if down(_VK_CONTROL) and not any(down(vk) for vk in (_VK_SHIFT, _VK_MENU, _VK_LWIN, _VK_RWIN)):
                                self._blocked = True
                                self._on_trigger()
                                return 1
                        elif self._blocked:
                            self._blocked = False
                            return 1
                return user32.CallNextHookEx(None, code, wparam, lparam)

            proc = HOOKPROC(kb)
            hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, proc, None, 0)
            ready.set()
            msg = wintypes.MSG()
            while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
                pass
            if hook:
                user32.UnhookWindowsHookEx(hook)

        threading.Thread(target=run, daemon=True).start()
        ready.wait(1)

    def stop(self):
        if self._tid:
            user32.PostThreadMessageW(self._tid, WM_QUIT, 0, 0)


def send_ctrl_c():
    """模拟一次 Ctrl+C(读选中文字的兜底办法)。"""
    vk_c = 0x43
    send_inputs([key_input(vk=_VK_CONTROL), key_input(vk=vk_c),
                 key_input(vk=vk_c, flags=_KEYEVENTF_KEYUP), key_input(vk=_VK_CONTROL, flags=_KEYEVENTF_KEYUP)])


# ---------- 回填校验(与 Mac 的 FillVerifier 一致) ----------
FILL_VERIFY_SECONDS = 0.6  # 最多等输入框多久
FILL_PATCH_MAX = 40        # 末尾缺多少字以内才补打


def _squeeze(text):
    return [c for c in text if not c.isspace()]


def missing_tail(typed, field):
    """输入框末尾缺的那截:"" 齐全;None 对不上(输入框末尾连打进去的开头都没有,无法判断)。
    比较时忽略空白和换行,不同输入框对换行的表示不一样。"""
    t, f = _squeeze(typed), _squeeze(field)
    if not t:
        return ""
    k = min(len(t), len(f))
    while k > 0 and f[len(f) - k:] != t[:k]:
        k -= 1
    if k == 0:
        return None
    if k == len(t):
        return ""
    seen = 0
    for i, c in enumerate(typed):  # 把"前 k 个非空白字"映射回原文位置,缺的是其后的部分
        if not c.isspace():
            seen += 1
            if seen == k:
                return typed[i + 1:]
    return ""


# ---------- 流式回填 ----------
# ---------- 复述守卫 ----------
class EchoGuard:
    """模型偶尔把截图里的上一句原样吐回来(与 macos/Sources/StreamingInput.swift 的 EchoGuard 一致)。
    开头与上一条结果一致时先攒着不写,攒够或结束时再判定:几乎相同 → 整条丢弃;不同 → 放行并补写。"""
    PROBE, DECIDE_AT = 8, 24

    def __init__(self, previous):
        self.previous = self.normalize(previous or "")
        self.held = ""
        self.decided = False
        self.blocked = False

    @staticmethod
    def normalize(text):
        """去掉标点和空白、转小写后再比较。"""
        return "".join(ch for ch in text if not ch.isspace()
                       and not unicodedata.category(ch).startswith("P")).lower()

    def admit(self, part):
        """返回这次可以写出去的文字(可能为空:还在攒,或已判定为复述)。"""
        if self.decided:
            return "" if self.blocked else part
        if len(self.previous) < self.PROBE:
            self.decided = True  # 上一条太短,不拦
            return part
        self.held += part
        norm = self.normalize(self.held)
        if len(norm) < self.PROBE:
            return ""
        # 开头和上一条不一样;攒到一定长度后开头已不像;或已比上一条明显长 → 不是复述,放行
        if (not self.previous.startswith(norm[:self.PROBE])
                or (len(norm) >= self.DECIDE_AT and not self.similar(norm, self.previous[:len(norm)]))
                or len(norm) > len(self.previous) + 6):
            return self._release()
        return ""

    def flush(self):
        """流结束时的最终判定,返回还没写出去的文字。"""
        if self.decided:
            return ""
        norm = self.normalize(self.held)
        self.blocked = bool(norm) and self.similar(norm, self.previous)
        out = "" if self.blocked else self.held
        self.decided, self.held = True, ""
        return out

    def _release(self):
        out, self.held, self.decided = self.held, "", True
        return out

    @staticmethod
    def similar(a, b):
        """编辑距离不超过较长一方的 20%,视为同一句话(容忍"的""了"这类增删和同音字)。"""
        if not a or not b:
            return False
        prev = list(range(len(b) + 1))
        for i, ca in enumerate(a, 1):
            cur = [i] + [0] * len(b)
            for j, cb in enumerate(b, 1):
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
            prev = cur
        return prev[-1] <= max(len(a), len(b)) * 0.20


class StreamingInput:
    """网络线程把增量文字 push 进来,独立的写入线程消费,不阻塞接收后续内容。"""

    def __init__(self, destination, timing_origin, copy_text, previous_text="", prefix=None):
        """prefix(第一段文字) -> 要先补打的字(接着上一句说时补回标点或空格),None 表示不补。"""
        self.destination = destination
        self._prefix = prefix
        self._guard = EchoGuard(previous_text)
        self.echo_blocked = False  # 结束后为 True:整条结果被判定为复述上一句,没有写入
        self.timing_origin = timing_origin
        self._copy_text = copy_text  # 写剪贴板的回调(在界面线程执行)
        self._queue = queue.Queue()
        self.received = ""
        self.failure = None if destination else "无法确认原输入目标，结果已保留在历史"
        self.wrote_first = False
        self.copied = False
        self.typed = ""  # 实际打进输入框的文字(含"接着说"补的前缀),回填后用来对末尾
        self._modifiers_checked = False
        # 回填期间单独按回车:先拦下记住,全部打完后再替用户按一次(否则半截内容会被发出去)
        self.enter_queued = False
        self.sent_enter = False
        self._monitor = ActivityMonitor(self._on_activity, on_enter=self._queue_enter)
        self._worker = threading.Thread(target=self._run, daemon=True)
        self._worker.start()

    def _queue_enter(self):
        if not self.enter_queued:
            log.info("回填中按了回车,打完后再发送")
        self.enter_queued = True

    def _on_activity(self, kind, _scan=None, _pt=None):
        self._stop(f"检测到{kind}操作，已停止回填；完整结果保留在历史")

    def _stop(self, message):
        if self.failure is None:
            self.failure = message

    def _can_write(self):
        if self.failure is None and not self.destination.is_current():
            self._stop("输入位置已改变，已停止回填；完整结果保留在历史")
        return self.failure is None

    def push(self, part):
        self._queue.put(part)

    def _run(self):
        while True:
            part = self._queue.get()
            if part is None:
                return
            self.received += part
            if self.failure is not None:
                continue
            self._write(self._guard.admit(part))

    def _write(self, text):
        if not text or self.failure is not None:
            return
        if self._prefix is not None:
            text = self._prefix(text) + text  # 只在真正要写第一段时补,整条被拦或失败就不补
            self._prefix = None
        if not self._modifiers_checked:
            wait_modifiers_released()
            self._modifiers_checked = True
        try:
            wrote = type_text(text, self._can_write)
            if wrote:
                self.typed += text
            if wrote and not self.wrote_first:
                self.wrote_first = True
                log.info("首次流式写入: %dms", (time.monotonic() - self.timing_origin) * 1000)
        except Exception:
            log.exception("回填失败")
            self._stop("文字输入失败，结果已保留在历史")

    def finish(self, send_enter=False, final_text=None):
        """等写入队列排空;成功时按需回车;完整结果没写完时复制全文。"""
        self._queue.put(None)
        self._worker.join()
        rest = self._guard.flush()
        if self._guard.blocked:
            self.echo_blocked = True
            self._monitor.stop()
            log.info("复述守卫: 结果与上一条几乎相同,未写入")
            return
        self._write(rest)  # 开头像上一句时攒着的字,判定不是复述后补写
        self._settle()  # 回车拦截要等校验结束再撤:校验期间按的回车照样攒着,字全落地了再发
        self._monitor.stop()  # 先停止拦截,之后用户再按回车就照常生效
        if (send_enter or self.enter_queued) and self.wrote_first and self._can_write():
            time.sleep(0.08)
            press_enter()
            self.sent_enter = True
        if final_text and self.failure is not None:
            self._copy_text(final_text)
            self.copied = True

    def _settle(self):
        """Chromium 类窗口回填后读回输入框,末尾缺一小截就补打一次。日志只记字数,不记文字。"""
        if self.failure is not None or not self.typed or not self.destination.chromium:
            return
        from learn import read_focused_text  # learn 也引用本模块,放这里避免循环导入
        start = time.monotonic()
        missing, readable, polls = None, False, 0
        while True:
            if not self._can_write():
                return
            polls += 1
            value = read_focused_text()
            if value is not None:
                readable = True
                missing = missing_tail(self.typed, value)
                if missing == "":
                    if polls > 1:
                        log.info("回填校验: 第 %d 次读回才齐,等了 %dms", polls, (time.monotonic() - start) * 1000)
                    return
            if time.monotonic() - start >= FILL_VERIFY_SECONDS:
                break
            time.sleep(0.05)
        if not readable:
            log.info("回填校验: 读不到输入框内容,跳过")
        elif missing is None:
            log.info("回填校验: 输入框内容和打进去的对不上,跳过(共 %d 字)", len(self.typed))
        elif len(missing) > FILL_PATCH_MAX:
            log.info("回填校验: 输入框末尾少 %d 字,超出补打范围,不动", len(missing))
        else:
            try:
                type_text(missing, self._can_write)
                self.typed += missing
                time.sleep(0.15)
                again = read_focused_text()
                ok = again is not None and missing_tail(self.typed, again) == ""
                log.info("回填校验: 输入框末尾少 %d 字,已补打,复查=%s", len(missing), "齐了" if ok else "仍不齐")
            except Exception:
                log.exception("回填校验: 补打失败")

    def abort(self):
        self._stop("识别失败")
        self._queue.put(None)
        self._worker.join()
        self._monitor.stop()
