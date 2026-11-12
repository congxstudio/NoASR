"""实验功能:在文本输入框内长按鼠标左键录音,松开提交。

- 低级鼠标钩子(WH_MOUSE_LL)只监听、不拦截,左键原有功能不受影响。
- 按下后 LONGPRESS 秒内鼠标基本没动,才去判断是不是输入框(判断在工作线程做,钩子回调必须快)。
- 判断规则(任一命中即可),每次判断都写日志,用于整理各软件的兼容情况:
  A 鼠标下的控件或其上几层是可编辑输入框(UI Automation)
  B 当前焦点控件可编辑,且鼠标在它的范围内
  C 前台窗口有系统文字光标(caret),且鼠标在该窗口内
"""
import ctypes
import logging
import math
import os
import queue
import threading
import time
from ctypes import wintypes

import engine

log = logging.getLogger("mouse")

LONGPRESS = 0.5       # 按住多久算长按(秒)
MOVE_TOLERANCE = 6    # 判定前允许的抖动(像素),超过视为在拖动选字;开始录音后移动不再影响

WH_MOUSE_LL = 14
WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP = 0x0200, 0x0201, 0x0202
WM_RBUTTONDOWN, WM_RBUTTONUP = 0x0204, 0x0205
LLMHF_INJECTED = 0x01
VK_LBUTTON = 0x01

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", wintypes.POINT), ("mouseData", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class GUITHREADINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("hwndActive", wintypes.HWND), ("hwndFocus", wintypes.HWND),
                ("hwndCapture", wintypes.HWND), ("hwndMenuOwner", wintypes.HWND),
                ("hwndMoveSize", wintypes.HWND), ("hwndCaret", wintypes.HWND),
                ("rcCaret", wintypes.RECT)]


HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = ctypes.c_ssize_t
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = wintypes.HHOOK


def _caret_window():
    """前台线程的系统文字光标所在窗口,没有则返回 None。"""
    fg = user32.GetForegroundWindow()
    tid = user32.GetWindowThreadProcessId(fg, None)
    info = GUITHREADINFO(cbSize=ctypes.sizeof(GUITHREADINFO))
    if tid and user32.GetGUIThreadInfo(tid, ctypes.byref(info)) and info.hwndCaret:
        return info.hwndCaret
    return None


def _window_contains(hwnd, x, y):
    r = wintypes.RECT()
    return bool(user32.GetWindowRect(hwnd, ctypes.byref(r))) and r.left <= x < r.right and r.top <= y < r.bottom


class MouseTrigger:
    def __init__(self, eng):
        self.engine = eng
        self._thread = None
        self._hook_tid = None
        self._jobs = queue.Queue()
        self._worker = None
        self._state = "idle"   # idle / pending(等待判定) / recording
        self._down_pos = (0, 0)
        self._token = 0        # 每次按下递增,丢弃过期的判定
        self._send = False     # 长按录音中点了右键:松开左键后自动回车发送
        self._swallow_rup = False  # 右键按下被拦截了,对应的松开也要拦截
        self._proc = HOOKPROC(self._hook)  # 保持引用,防止被回收

    # ---------- 生命周期 ----------
    def start(self):
        if self._thread:
            return
        self._worker = threading.Thread(target=self._work, daemon=True)
        self._worker.start()
        self._thread = threading.Thread(target=self._hook_loop, daemon=True)
        self._thread.start()
        log.info("输入框长按左键录音:已开启")

    def stop(self):
        if not self._thread:
            return
        if self._hook_tid:
            user32.PostThreadMessageW(self._hook_tid, 0x0012, 0, 0)  # WM_QUIT
        self._jobs.put(None)
        self._thread = self._worker = None
        self._hook_tid = None
        if self._state == "recording":
            self.engine.cancel_external()
        self._state = "idle"
        log.info("输入框长按左键录音:已关闭")

    def _hook_loop(self):
        self._hook_tid = kernel32.GetCurrentThreadId()
        hook = user32.SetWindowsHookExW(WH_MOUSE_LL, self._proc, None, 0)
        if not hook:
            log.error("安装鼠标钩子失败: %s", ctypes.GetLastError())
            return
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            pass
        user32.UnhookWindowsHookEx(hook)

    # ---------- 钩子回调(必须快,不做耗时操作) ----------
    def _hook(self, n_code, w_param, l_param):
        if n_code == 0:
            try:
                ms = ctypes.cast(l_param, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
                if not ms.flags & LLMHF_INJECTED and self._on_mouse(w_param, ms.pt.x, ms.pt.y):
                    return 1  # 拦截:不传给目标程序(长按录音中的右键,避免弹出右键菜单)
            except Exception:
                log.exception("鼠标钩子处理失败")
        return user32.CallNextHookEx(None, n_code, w_param, l_param)

    def _on_mouse(self, msg, x, y):
        """返回 True 表示拦截这个鼠标事件。"""
        if msg == WM_RBUTTONDOWN and self._state == "recording":
            self._send = True
            self._swallow_rup = True
            self.engine.mark_send()
            return True
        if msg == WM_RBUTTONUP and self._swallow_rup:
            self._swallow_rup = False
            return True
        if msg == WM_LBUTTONDOWN:
            if self._state == "recording":
                return
            self._token += 1
            self._state = "pending"
            self._send = False
            self._down_pos = (x, y)
            token = self._token
            threading.Timer(LONGPRESS, lambda: self._jobs.put(("check", token, x, y))).start()
        elif msg == WM_MOUSEMOVE:
            if self._state == "pending" and math.dist(self._down_pos, (x, y)) > MOVE_TOLERANCE:
                self._state = "idle"  # 判定前就在拖动,视为选字
        elif msg == WM_LBUTTONUP:
            if self._state == "recording":
                self._state = "idle"
                self.engine.end_external(send_enter=self._send)
                if self._send:
                    log.info("长按 + 右键:输入后自动发送")
            else:
                self._state = "idle"

    # ---------- 工作线程:UI Automation 判定 ----------
    def _work(self):
        inspector = None
        try:
            import uia
            inspector = uia.Inspector()
        except Exception:
            log.exception("UI Automation 初始化失败,只能用文字光标规则判断")
        while True:
            job = self._jobs.get()
            if job is None:
                return
            _, token, x, y = job
            if token != self._token or self._state != "pending":
                continue
            if not user32.GetAsyncKeyState(VK_LBUTTON) & 0x8000:
                continue
            t0 = time.time()
            hit, detail = self._judge(inspector, x, y)
            app = engine.describe_app(*engine.get_foreground_app()).split("（")[0] or "(本程序或未知)"
            log.info("长按判定 %s | %s | 规则:%s | 耗时%.0fms | %s",
                     "✓输入框" if hit else "✗非输入框", app, hit or "-", (time.time() - t0) * 1000, detail)
            if hit and token == self._token and self._state == "pending":
                self._state = "recording"
                self.engine.begin_external()

    @staticmethod
    def _judge(inspector, x, y):
        details = []
        if inspector:
            try:
                if inspector.is_password_at(x, y):
                    return "", "受保护输入框，不启动语音"
            except Exception:
                return "", "无法检查输入保护，不启动鼠标语音"
            try:
                ok, info = inspector.inspect_point(x, y)
                details.append(f"A鼠标下:{info}")
                if ok:
                    return "A", " ; ".join(details)
            except Exception as e:
                details.append(f"A失败:{e}")
            try:
                ok, info = inspector.inspect_focus(x, y)
                details.append(f"B焦点:{info}")
                if ok:
                    return "B", " ; ".join(details)
            except Exception as e:
                details.append(f"B失败:{e}")
        caret = _caret_window()
        details.append(f"C光标:{'有' if caret else '无'}")
        if caret and _window_contains(user32.GetAncestor(caret, 2), x, y):  # GA_ROOT
            return "C", " ; ".join(details)
        return "", " ; ".join(details)
