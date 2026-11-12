"""录音开始时截取前台窗口(取不到时截鼠标所在屏幕),作为识别的语境参考。规则与 macos/Sources/Screenshot.swift 对齐。

- 在后台线程截图和压缩,不阻塞开麦;录音结束时最多等到 8 秒(从截图开始计)就放弃,只发语音。
- 最长边 1280、JPEG 质量 70,一次编码;原图不落盘。
- 截的是屏幕上看得到的画面(BitBlt),不需要额外授权。日志不记录窗口标题和画面内容。
"""
import ctypes
import logging
import threading
import time
from ctypes import wintypes

from PySide6.QtCore import QBuffer, QByteArray, QIODevice, Qt
from PySide6.QtGui import QImage

log = logging.getLogger("screenshot")
user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
dwmapi = ctypes.windll.dwmapi
# 句柄在 64 位下要按指针传递,不能让 ctypes 默认截成 int
_H = ctypes.c_void_p
user32.GetDC.restype = _H
user32.GetDC.argtypes = [_H]
user32.ReleaseDC.argtypes = [_H, _H]
gdi32.CreateCompatibleDC.restype = _H
gdi32.CreateCompatibleDC.argtypes = [_H]
gdi32.CreateCompatibleBitmap.restype = _H
gdi32.CreateCompatibleBitmap.argtypes = [_H, ctypes.c_int, ctypes.c_int]
gdi32.SelectObject.restype = _H
gdi32.SelectObject.argtypes = [_H, _H]
gdi32.DeleteObject.argtypes = [_H]
gdi32.DeleteDC.argtypes = [_H]
gdi32.BitBlt.argtypes = [_H, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, _H,
                         ctypes.c_int, ctypes.c_int, wintypes.DWORD]
gdi32.GetDIBits.argtypes = [_H, _H, wintypes.UINT, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]

MAX_EDGE = 1280
QUALITY = 70
TIMEOUT = 8.0
DWMWA_EXTENDED_FRAME_BOUNDS = 9
MONITOR_DEFAULTTONEAREST = 2
SRCCOPY, CAPTUREBLT = 0x00CC0020, 0x40000000
# 桌面、任务栏这类不是"应用窗口",改截整屏
SHELL_CLASSES = {"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"}


class _MONITORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT),
                ("rcWork", wintypes.RECT), ("dwFlags", wintypes.DWORD)]


class _BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD),
                ("biCompression", wintypes.DWORD), ("biSizeImage", wintypes.DWORD),
                ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


def window_rect(hwnd):
    """窗口在屏幕上的实际范围(物理像素,不含阴影);拿不到返回 None。"""
    if not hwnd or not user32.IsWindowVisible(hwnd) or user32.IsIconic(hwnd):
        return None
    r = wintypes.RECT()
    if dwmapi.DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, ctypes.byref(r), ctypes.sizeof(r)) != 0:
        if not user32.GetWindowRect(hwnd, ctypes.byref(r)):
            return None
    if r.right - r.left < 2 or r.bottom - r.top < 2:
        return None
    return r.left, r.top, r.right, r.bottom


def monitor_rect(x, y, work=False):
    """某个点所在屏幕的范围(物理像素)。work=True 时去掉任务栏。"""
    mon = user32.MonitorFromPoint(wintypes.POINT(x, y), MONITOR_DEFAULTTONEAREST)
    info = _MONITORINFO(cbSize=ctypes.sizeof(_MONITORINFO))
    user32.GetMonitorInfoW(mon, ctypes.byref(info))
    r = info.rcWork if work else info.rcMonitor
    return r.left, r.top, r.right, r.bottom


def cursor_pos():
    pt = wintypes.POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    return pt.x, pt.y


def is_app_window(hwnd):
    if not hwnd:
        return False
    buf = ctypes.create_unicode_buffer(64)
    user32.GetClassNameW(hwnd, buf, 64)
    return buf.value not in SHELL_CLASSES


def _grab(left, top, right, bottom):
    """截取屏幕上的一块区域,返回 QImage。"""
    w, h = right - left, bottom - top
    screen = user32.GetDC(None)
    mem = gdi32.CreateCompatibleDC(screen)
    bmp = gdi32.CreateCompatibleBitmap(screen, w, h)
    old = gdi32.SelectObject(mem, bmp)
    try:
        gdi32.BitBlt(mem, 0, 0, w, h, screen, left, top, SRCCOPY | CAPTUREBLT)
        header = _BITMAPINFOHEADER(biSize=ctypes.sizeof(_BITMAPINFOHEADER), biWidth=w, biHeight=-h,
                                   biPlanes=1, biBitCount=32, biCompression=0)
        buf = ctypes.create_string_buffer(w * h * 4)
        if not gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(header), 0):
            raise OSError("GetDIBits 失败")
        return QImage(buf.raw, w, h, w * 4, QImage.Format_RGB32).copy()
    finally:
        gdi32.SelectObject(mem, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mem)
        user32.ReleaseDC(None, screen)


def compress(image):
    """缩到最长边 1280,编码为 JPEG 字节。"""
    if max(image.width(), image.height()) > MAX_EDGE:
        image = image.scaled(MAX_EDGE, MAX_EDGE, Qt.KeepAspectRatio, Qt.SmoothTransformation)
    data = QByteArray()
    buf = QBuffer(data)
    buf.open(QIODevice.WriteOnly)
    if not image.save(buf, "JPEG", QUALITY):
        raise OSError("JPEG 编码失败")
    return bytes(data)


def capture(hwnd, pointer):
    """返回 (jpeg 字节或 None, 来源 window/display, 说明)。"""
    try:
        rect = window_rect(hwnd) if is_app_window(hwnd) else None
        source = "window"
        if rect:
            # 只截窗口在屏幕内的部分
            vx, vy = user32.GetSystemMetrics(76), user32.GetSystemMetrics(77)
            vw, vh = user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)
            rect = (max(rect[0], vx), max(rect[1], vy), min(rect[2], vx + vw), min(rect[3], vy + vh))
            if rect[2] - rect[0] < 2 or rect[3] - rect[1] < 2:
                rect = None
        if not rect:
            rect, source = monitor_rect(*pointer), "display"
        jpeg = compress(_grab(*rect))
        log.info("截图准备: source=%s bytes=%d", source, len(jpeg))
        return jpeg, source, ""
    except Exception:
        log.exception("截图失败")
        return None, None, "截图未完成，本次仅使用录音"


class ScreenshotJob:
    """每次录音一个后台截图任务;取消或超时后迟到的结果直接丢弃。"""

    def __init__(self, hwnd, pointer):
        self._done = threading.Event()
        self._result = None
        self._started = time.monotonic()
        threading.Thread(target=self._run, args=(hwnd, pointer), daemon=True).start()

    def _run(self, hwnd, pointer):
        result = capture(hwnd, pointer)
        if not self._done.is_set():
            self._result = result
            self._done.set()

    def value(self):
        """等截图完成(从开始截图算最多 8 秒),返回 (jpeg, source, note)。"""
        remaining = TIMEOUT - (time.monotonic() - self._started)
        if not self._done.wait(max(0.0, remaining)) or self._result is None:
            self._done.set()
            return None, None, "截图超时，本次仅使用录音"
        return self._result

    def cancel(self):
        self._done.set()
