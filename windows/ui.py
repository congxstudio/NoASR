"""界面:设置窗口(通用 / 模型配置 / 麦克风与提示音 / 历史记录)、首次引导、录音胶囊。

布局与功能对齐 macos/Sources/UI.swift;材质参考 Mac 的轻薄玻璃,保留 Windows 上的清晰对比度:
浅色淡彩底光、珍珠白渐变卡片与柔和高光,交互状态使用 Windows 默认蓝色;
另有深色外观(跟随系统或手动选择),颜色都在 PALETTES 两套配色表里,切换时 set_theme() 后重新套样式表即可。
文字和编辑区域保持稳定对比度,不通过降低整体透明度实现玻璃感。
设置改动立即保存,没有"保存"按钮。
"""
import ctypes
import math
import os
import queue
import threading
from collections import deque
from ctypes import wintypes

from PySide6.QtCore import QAbstractAnimation, QByteArray, QEasingCurve, QEvent, QObject, QPoint, QPointF, QRect, QRectF, QSize, Qt, QTimer, QVariantAnimation, Signal
from PySide6.QtGui import (QColor, QFont, QFontMetrics, QGuiApplication, QIcon, QLinearGradient, QRadialGradient,
                           QPainter, QPainterPath, QPen, QPixmap)
from PySide6.QtSvg import QSvgRenderer
from PySide6.QtWidgets import (
    QAbstractButton, QButtonGroup, QComboBox, QDialog, QFrame, QHBoxLayout, QLabel, QLineEdit,
    QMessageBox, QPlainTextEdit, QPushButton, QRadioButton, QScrollArea, QSlider,
    QStackedWidget, QVBoxLayout, QWidget,
)

import config
import engine
from shortcuts import validate_candidate

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")
FONT = "Microsoft YaHei UI"

# 两套配色(珍珠白薄玻璃 / 烟灰玻璃,对比度优先)。#AARRGGBB 表示带透明度。
PALETTES = {
    "light": {
        "text": "#404b57", "secondary": "#616f7e", "title": "#4c5766", "section": "#515d6a",
        "accent": "#0078d4", "accent_hover": "#0067c0", "accent_text": "#ffffff", "accent_border": "#0067c0",
        "link_hover": "#0067c0", "selection": "#0078d4", "blue": "#0078d4", "error": "#b35f50",
        "window": "#f1f4f7", "win_border": "#f2ffffff", "card": "#efffffff", "card_border": "#f0ffffff",
        "field": "#f4ffffff", "border": "#dbe4e9", "field_line": "#b9c9cf",
        "button": "#f5ffffff", "button_edge": "#cdd9df", "button_hover": "#ffffff", "button_pressed": "#e6edf0",
        "button_pressed_text": "#0067c0", "disabled_text": "#98a3ae", "disabled_bg": "#eef2f5",
        "list_sel": "#dceeff", "menu_sel": "#e5f1fb", "menu_border": "#d8e1e6", "separator": "#e0e7ec",
        "groove": "#dce5e8", "slider_knob": "#ffffff", "scrollbar": "rgba(79,99,116,0.24)",
        "keycap": "#f5ffffff", "keycap_border": "#ffffff", "keycap_edge": "#cdd9df",
        "seg_bg": "#a0e6ecf0", "seg_border": "#b8d9e2e8", "seg_sel": "#f0ffffff", "seg_sel_border": "#ffffff",
        "seg_text": "#64717e", "knob_on": "#ffffff", "toggle_off": "#94a2ae", "toggle_off_bg": "#b8ffffff",
        "toggle_off_hover": "#eff5f6", "glyph_disabled": "#bcc7d0", "glyph_inactive": "#94a1ae",
        "tint": "#647b8a",
        "step_line": "#a0bec8d4", "step_off": "#a0a0a0", "step_off_bg": "#ffffff",
        "cap_top": "#f5ffffff", "cap_bottom": "#ebf6f8fb", "cap_edge": "#ffffff", "cap_inner": "#a0dce2ea",
        "cap_shadow": "#324664", "cap_text": "#5b6268", "spin_track": "#c8ced6", "spin_head": "#78808a",
        "notice": "#6e8caf",
        "brand_lilac": "#28cbbcf1", "brand_mint": "#20b9e7d9", "brand_peach": "#18f5d6c7",
        "brand_text": "#58616e",
        "card_top": "#f8ffffff", "card_bottom": "#dcf7f9fb", "surface_highlight": "#c8ffffff",
        "button_top": "#fcffffff", "button_bottom": "#e7edf2f5",
        "primary_top": "#0078d4", "primary_bottom": "#0078d4", "primary_hover": "#0067c0",
        "toggle_on_top": "#0078d4", "toggle_on_bottom": "#0078d4", "toggle_on_border": "#0067c0",
        "knob_bottom": "#f2f6fc", "knob_border": "#b4ffffff",
        "nav_sel": "#b8ffffff", "nav_border": "#f0ffffff",
        "step_active": "#dceeff", "step_active_border": "#80bbee",
        "shadow": "#71859a", "ambient_lilac": "#18bdb2e5", "ambient_mint": "#16b1e0d6", "ambient_peach": "#12f2d2c1",
    },
    "dark": {
        "text": "#e3e8ef", "secondary": "#afbac7", "title": "#eef1f6", "section": "#d2dce7",
        "accent": "#60cdff", "accent_hover": "#8bd9ff", "accent_text": "#ffffff", "accent_border": "#60aee8",
        "link_hover": "#8bd9ff", "selection": "#0078d4", "blue": "#60cdff", "error": "#e7a495",
        "window": "#232730", "win_border": "#52636f80", "card": "#ed303741", "card_border": "#424d5a",
        "field": "#303741", "border": "#4b5664", "field_line": "#677687",
        "button": "#343c48", "button_edge": "#222a33", "button_hover": "#414b58", "button_pressed": "#2b323e",
        "button_pressed_text": "#c8d8dc", "disabled_text": "#758190", "disabled_bg": "#292f39",
        "list_sel": "#254c70", "menu_sel": "#293f56", "menu_border": "#4b5664", "separator": "#424c58",
        "groove": "#46525f", "slider_knob": "#e8eef6", "scrollbar": "rgba(200,217,228,0.25)",
        "keycap": "#353f4b", "keycap_border": "#536171", "keycap_edge": "#242c36",
        "seg_bg": "#29303a", "seg_border": "#46515f", "seg_sel": "#465463", "seg_sel_border": "#657485",
        "seg_text": "#bdc9d5", "knob_on": "#ffffff", "toggle_off": "#8c9aa8", "toggle_off_bg": "#2d3540",
        "toggle_off_hover": "#38434f", "glyph_disabled": "#5d6977", "glyph_inactive": "#8898a8",
        "tint": "#ffffff",
        "step_line": "#a0555555", "step_off": "#777777", "step_off_bg": "#2b2b2b",
        "cap_top": "#f8303030", "cap_bottom": "#f5282828", "cap_edge": "#28ffffff", "cap_inner": "#12ffffff",
        "cap_shadow": "#000000", "cap_text": "#f0f0f0", "spin_track": "#5a5a5a", "spin_head": "#c8c8c8",
        "notice": "#8cb4dc",
        "brand_lilac": "#146e5b94", "brand_mint": "#123f7169", "brand_peach": "#10785d59",
        "brand_text": "#d8e0ec",
        "card_top": "#ee343b46", "card_bottom": "#ed2d333d", "surface_highlight": "#226d8094",
        "button_top": "#3a424e", "button_bottom": "#303744",
        "primary_top": "#0078d4", "primary_bottom": "#0078d4", "primary_hover": "#1687e0",
        "toggle_on_top": "#0078d4", "toggle_on_bottom": "#0078d4", "toggle_on_border": "#60aee8",
        "knob_bottom": "#eaf2fc", "knob_border": "#d0ffffff",
        "nav_sel": "#b33d4c5b", "nav_border": "#667c8b9c",
        "step_active": "#254c70", "step_active_border": "#60aee8",
        "shadow": "#000000", "ambient_lilac": "#125b4d77", "ambient_mint": "#12365d59", "ambient_peach": "#0a705247",
    },
}
P = PALETTES["light"]   # 当前配色;set_theme() 切换
THEME = "light"


def C(key, alpha=None):
    """从当前配色取颜色;alpha 给定时覆盖透明度(0~255)。"""
    c = QColor(P[key])
    if alpha is not None:
        c.setAlpha(alpha)
    return c


TEXT = SECONDARY = CONTROL = TITLE = SECTION = ACCENT = BLUE = CORAL = CARD_FILL = CARD_BORDER = None
STYLE = ""

MODES = {"both": "同时支持", "hold": "长按模式", "toggle": "点按模式"}
MODE_HINTS = {"both": "短按开始或结束，长按松开提交", "hold": "按住说话，松开提交",
              "toggle": "按一下开始，再按一下提交"}
KEY_NAMES = {"ctrl": "Ctrl", "right ctrl": "右 Ctrl", "left ctrl": "左 Ctrl", "alt": "Alt",
             "right alt": "右 Alt", "left alt": "左 Alt", "shift": "Shift", "right shift": "右 Shift",
             "left shift": "左 Shift", "windows": "Win", "left windows": "左 Win", "right windows": "右 Win",
             "space": "空格", "caps lock": "Caps Lock", "enter": "回车", "esc": "Esc"}
KEY_NAMES.update({"plus": "加号", "left": "←", "right": "→", "up": "↑", "down": "↓",
                  "tab": "Tab", "backspace": "退格", "delete": "Delete"})
# 左侧修饰键的事件名不带 left(左 Ctrl 就叫 "ctrl"),右侧是 "right ctrl"
LEFT_SIDE = {"ctrl": "left ctrl", "alt": "left alt", "shift": "left shift", "windows": "left windows"}
MODIFIER_ORDER = ("ctrl", "alt", "shift", "windows")


def _base_key(name):
    return name.split(" ", 1)[1] if name.startswith(("left ", "right ")) else name


def hotkey_from_events(events):
    """按下的键 → 带左右的热键名,修饰键在前,如 "right ctrl+space"。"""
    names = []
    for e in events:
        if e.scan_code == 541:
            continue  # AltGr 附带的假 Ctrl
        n = LEFT_SIDE.get((e.name or "").lower(), (e.name or "").lower())
        if n == "+":
            n = "plus"
        if n and n not in names:
            names.append(n)
    mods = sorted((n for n in names if _base_key(n) in MODIFIER_ORDER), key=lambda n: MODIFIER_ORDER.index(_base_key(n)))
    return "+".join(mods + [n for n in names if _base_key(n) not in MODIFIER_ORDER])


def read_sided_hotkey(cancel=None):
    """等用户按下一组键、松开第一个键时返回。
    不用 keyboard.read_hotkey:它拼名字时会去掉 left/right,按右 Alt 只得到 "alt"。"""
    import keyboard
    q = queue.Queue()
    hooked = keyboard.hook(q.put)
    downs = []
    try:
        while True:
            if cancel is not None and cancel.is_set():
                return ""
            try:
                e = q.get(timeout=0.1)
            except queue.Empty:
                continue
            if e.event_type == keyboard.KEY_DOWN:
                if e.name == "esc":
                    return "esc"
                downs.append(e)
            elif downs:
                return hotkey_from_events(downs)
    finally:
        keyboard.unhook(hooked)


class ShortcutRecorder(QObject):
    """可取消的按键录入;过期线程结果不再修改界面或配置。"""
    finished = Signal(str)
    _result = Signal(int, str)

    def __init__(self, parent):
        super().__init__(parent)
        self._generation = 0
        self._cancel = None
        self._result.connect(self._deliver)

    def start(self):
        self.cancel()
        generation = self._generation
        cancel = self._cancel = threading.Event()

        def worker():
            try:
                name = read_sided_hotkey(cancel)
            except Exception:
                name = ""
            if not cancel.is_set():
                self._result.emit(generation, name)

        threading.Thread(target=worker, daemon=True).start()

    def _deliver(self, generation, name):
        if generation == self._generation and self._cancel and not self._cancel.is_set():
            self.finished.emit(name)

    def cancel(self):
        self._generation += 1
        if self._cancel:
            self._cancel.set()

def build_style():
    """按当前配色生成整套样式表。"""
    c = P
    return f"""
QWidget {{ font-family: "{FONT}"; color: {c['text']}; }}
QLabel {{ background: transparent; }}
QLabel[tone="secondary"] {{ color: {c['secondary']}; }}
QLabel[tone="title"] {{ color: {c['title']}; }}
QLabel[tone="section"] {{ color: {c['section']}; }}
QLabel[tone="error"] {{ color: {c['error']}; }}
QLabel#keycap {{ background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 {c['button_top']}, stop:1 {c['button_bottom']});
    border: 1px solid {c['keycap_border']}; border-bottom: 1px solid {c['keycap_edge']};
    border-radius: 9px; padding: 6px 16px; }}
QLabel#thumb {{ border: 1px solid {c['card_border']}; border-radius: 6px; }}
QLineEdit, QPlainTextEdit, QComboBox {{
    background: {c['field']}; border: 1px solid {c['border']}; border-bottom: 1px solid {c['field_line']};
    border-radius: 8px; padding: 6px 10px; font-size: 13px; color: {c['text']};
    selection-background-color: {c['selection']}; selection-color: white;
}}
QLineEdit:focus, QPlainTextEdit:focus, QComboBox:focus {{ border-bottom: 2px solid {c['accent']}; }}
QComboBox {{ padding-right: 34px; }}
QComboBox::drop-down {{ border: none; width: 30px; }}
QComboBox::down-arrow {{ image: none; width: 0; height: 0; }}
QComboBox QAbstractItemView {{ background: {c['field']}; border: 1px solid {c['border']}; selection-background-color: {c['list_sel']};
    selection-color: {c['text']}; color: {c['text']}; outline: none; padding: 4px; }}
QPushButton {{
    background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 {c['button_top']}, stop:1 {c['button_bottom']});
    border: 1px solid {c['keycap_border']}; border-bottom: 1px solid {c['button_edge']};
    border-radius: 9px; padding: 6px 16px; font-size: 13px; color: {c['text']};
}}
QPushButton:hover {{ background: {c['button_hover']}; }}
QPushButton:focus {{ border: 1px solid {c['accent']}; }}
QPushButton:pressed {{ background: {c['button_pressed']}; color: {c['button_pressed_text']}; }}
QPushButton:disabled {{ color: {c['disabled_text']}; background: {c['disabled_bg']}; }}
QPushButton[prominent="true"] {{ background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 {c['primary_top']}, stop:1 {c['primary_bottom']});
    border: 1px solid {c['accent_border']}; color: {c['accent_text']}; }}
QPushButton[prominent="true"]:hover {{ background: {c['primary_hover']}; }}
QPushButton[flat="true"] {{ background: transparent; border: none; color: {c['accent']}; padding: 2px 6px; }}
QPushButton[flat="true"]:hover {{ color: {c['link_hover']}; }}
QScrollArea, QScrollArea > QWidget > QWidget {{ background: transparent; border: none; }}
QScrollBar:vertical {{ background: transparent; width: 8px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: {c['scrollbar']}; border-radius: 3px; min-height: 30px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QScrollArea#history QScrollBar:vertical {{ margin: 44px 3px 24px 2px; }}
QFrame#separator {{ background: {c['card_border']}; border: none; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}
QRadioButton {{ font-size: 13.5px; spacing: 8px; color: {c['text']}; }}
QRadioButton::indicator {{ width: 14px; height: 14px; border-radius: 8px; border: 1px solid {c['toggle_off']}; background: {c['field']}; }}
QRadioButton::indicator:checked {{ border-color: {c['accent']}; background: qradialgradient(cx:0.5, cy:0.5, radius:0.5, fx:0.5, fy:0.5,
    stop:0 {c['accent']}, stop:0.48 {c['accent']}, stop:0.55 {c['field']}, stop:1 {c['field']}); }}
QSlider::groove:horizontal {{ height: 4px; background: {c['groove']}; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {c['toggle_on_bottom']}; border-radius: 2px; }}
QSlider::handle:horizontal {{ background: {c['slider_knob']}; border: 5px solid {c['toggle_on_bottom']}; width: 10px; height: 10px;
    margin: -8px 0; border-radius: 10px; }}
QMenu {{ background: {c['field']}; border: 1px solid {c['menu_border']}; border-radius: 6px; padding: 4px; font-size: 13px; }}
QMenu::item {{ padding: 6px 28px 6px 14px; border-radius: 4px; color: {c['text']}; background: transparent; }}
QMenu::item:selected {{ background: {c['menu_sel']}; }}
QMenu::item:disabled {{ color: {c['disabled_text']}; }}
QMenu::separator {{ height: 1px; background: {c['separator']}; margin: 4px 8px; }}
QToolTip {{ background: {c['field']}; color: {c['text']}; border: 1px solid {c['border']}; padding: 6px; }}
"""


def set_theme(dark):
    """切换浅色/深色:更新配色和样式表。之后对已打开的窗口重新 setStyleSheet(STYLE) 并刷新。"""
    global P, THEME, TEXT, SECONDARY, CONTROL, TITLE, SECTION, ACCENT, BLUE, CORAL, CARD_FILL, CARD_BORDER, STYLE
    THEME = "dark" if dark else "light"
    P = PALETTES[THEME]
    TEXT, SECONDARY, TITLE, SECTION = C("text"), C("secondary"), C("title"), C("section")
    CONTROL = TEXT
    ACCENT, BLUE, CORAL = C("accent"), C("blue"), C("error")
    CARD_FILL, CARD_BORDER = C("card"), C("card_border")
    STYLE = build_style()


def system_is_dark():
    """Windows 当前是不是深色模式(设置 → 个性化 → 颜色 → 应用模式)。"""
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            return winreg.QueryValueEx(k, "AppsUseLightTheme")[0] == 0
    except OSError:
        return False


set_theme(False)


def make_icon_pixmap(size=64):
    """OneMore 淡彩玻璃图标;按实际显示尺寸平滑缩放。"""
    return QIcon(config.ICON_PATH).pixmap(size, size)


def font(px, weight=QFont.Normal):
    f = QFont(FONT)
    f.setPixelSize(round(px))
    f.setWeight(weight)
    return f


def label(text, px=14, color=None, weight=QFont.Normal, wrap=False):
    """color 传 TEXT / SECONDARY / TITLE / SECTION / CORAL 之一;用 tone 属性交给样式表上色,切换外观时自动变。"""
    w = QLabel(text)
    w.setFont(font(px, weight))
    tone = {id(SECONDARY): "secondary", id(TITLE): "title", id(SECTION): "section", id(CORAL): "error"}.get(id(color))
    if tone:
        w.setProperty("tone", tone)
    w.setWordWrap(wrap)
    return w


def note(text, px=12):
    return label(text, px, SECONDARY, wrap=True)


def hotkey_display(hotkey):
    return " + ".join(KEY_NAMES.get(k.strip(), k.strip().upper() if len(k.strip()) == 1 else k.strip().title())
                      for k in hotkey.split("+") if k.strip())


def cost_text(yuan):
    """展示时换算单位:不到 1 毛显示"分"。"""
    if yuan is None or yuan < 0:
        return "—"
    if 0 < yuan < 0.0001:
        return "<0.01 分"
    if yuan < 0.1:
        return f"{yuan * 100:.2f}".rstrip("0").rstrip(".") + " 分"
    return f"{yuan:.2f}".rstrip("0").rstrip(".") + " 元"


# ---------- 沉浸式窗口 ----------
_user32 = ctypes.windll.user32
_user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
_user32.GetWindowLongPtrW.argtypes = [ctypes.c_void_p, ctypes.c_int]
_user32.SetWindowLongPtrW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_ssize_t]
WM_NCCALCSIZE, WM_NCHITTEST = 0x0083, 0x0084
WM_NCLBUTTONDBLCLK = 0x00A3
HTCLIENT, HTCAPTION = 1, 2
HTLEFT, HTRIGHT, HTTOP, HTTOPLEFT, HTTOPRIGHT, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT = range(10, 18)
CAPTION_H = 40   # 顶部可拖动区域高度(逻辑像素);其中的空白处可拖动,按钮等控件照常可点
TITLE_TOP = 40    # 页面标题离窗口顶端的距离(与 Mac 一致,在右上角按钮下方)
RESIZE_EDGE = 8  # 窗口可见边缘内侧也能拖动改变大小的宽度
ICON_FONT = "Segoe Fluent Icons"


class CaptionButtons(QWidget):
    """右上角自绘的最小化 / 最大化 / 关闭按钮(图标用系统自带的 Segoe Fluent Icons)。"""
    BW, BH = 46, 32

    def __init__(self, window, maximizable):
        super().__init__(window)
        self.win = window
        self.keys = ["min", "max", "close"] if maximizable else ["min", "close"]
        self.hover = None
        self.pressed = None
        self.setMouseTracking(True)
        self.setFixedSize(self.BW * len(self.keys), self.BH)

    def rect_of(self, key):
        i = self.keys.index(key)
        return QRect(i * self.BW, 0, self.BW, self.BH)

    def key_at(self, pos):
        for k in self.keys:
            if self.rect_of(k).contains(pos):
                return k
        return None

    def set_hover(self, key):
        if key != self.hover:
            self.hover = key
            self.update()

    def mouseMoveEvent(self, e):
        self.set_hover(self.key_at(e.position().toPoint()))

    def leaveEvent(self, e):
        self.set_hover(None)

    def mousePressEvent(self, e):
        self.pressed = self.key_at(e.position().toPoint())
        self.update()

    def mouseReleaseEvent(self, e):
        key = self.key_at(e.position().toPoint())
        pressed, self.pressed = self.pressed, None
        self.update()
        if key and key == pressed:
            if key == "min":
                self.win.showMinimized()
            elif key == "max":
                self.win.toggle_maximized()
            elif key == "close":
                self.win.close()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        # 关闭按钮的红底不能伸出窗口的圆角
        clip = QPainterPath()
        clip.addRoundedRect(QRectF(self.win.content_rect()).translated(-QPointF(self.pos())),
                            self.win.radius(), self.win.radius())
        p.setClipPath(clip)
        f = QFont(ICON_FONT)
        f.setPixelSize(10)
        p.setFont(f)
        glyph = {"min": "", "max": "" if self.win.is_maximized() else "", "close": ""}
        active = self.win.isActiveWindow()
        for k in self.keys:
            r = self.rect_of(k)
            color = TEXT if active else C("glyph_inactive")
            if k == self.hover or k == self.pressed:
                if k == "close":
                    p.fillRect(r, QColor("#c42b1c") if not self.pressed else QColor("#c83c30"))
                    color = QColor("white")
                else:
                    p.fillRect(r, C("tint", 20 if k == self.pressed else 12))
            p.setPen(color)
            p.drawText(r, Qt.AlignCenter, glyph[k])


class ImmersiveWindow(QWidget):
    """去掉系统标题栏、内容铺到窗口顶端、22 像素圆角(与 Mac 一致)的窗口。

    做法:透明(分层)无边框窗口,自己画圆角外形和四周阴影;阴影那一圈兼作拖动改变大小的边缘。
    分层窗口和系统最大化配合不好(最大化后不重绘),所以最大化由 toggle_maximized() 自己实现:
    铺满屏幕可用区域、去掉圆角和阴影。代价(用户已确认):没有"拖到屏幕顶端自动最大化"和
    "悬停最大化按钮弹出的分屏布局菜单"。
    子类建好布局后,窗口四周会自动留出阴影边距。"""
    SHADOW = 16   # 阴影宽度
    RADIUS = 22   # 圆角

    def __init__(self, resizable=True):
        super().__init__()
        self._resizable = resizable
        self._max = False
        self._normal_geo = None
        self.setWindowFlags(Qt.Window | Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.caption = CaptionButtons(self, maximizable=resizable)
        self._styled = False

    # 内容尺寸 → 窗口尺寸(加上四周阴影)
    def set_content_minimum(self, w, h):
        self.setMinimumSize(w + 2 * self.SHADOW, h + 2 * self.SHADOW)

    def resize_content(self, w, h):
        self.resize(w + 2 * self.SHADOW, h + 2 * self.SHADOW)

    def fix_content_size(self, w, h):
        self.setFixedSize(w + 2 * self.SHADOW, h + 2 * self.SHADOW)

    def margin(self):
        return 0 if self._max else self.SHADOW

    def radius(self):
        return 0 if self._max else self.RADIUS

    def content_rect(self):
        m = self.margin()
        return self.rect().adjusted(m, m, -m, -m)

    def is_maximized(self):
        return self._max

    def toggle_maximized(self):
        if not self._resizable:
            return
        if self._max:
            self._max = False
            self._apply_margins()
            if self._normal_geo:
                self.setGeometry(self._normal_geo)
        else:
            self._normal_geo = self.geometry()
            screen = QGuiApplication.screenAt(self.geometry().center()) or QGuiApplication.primaryScreen()
            self._max = True
            self._apply_margins()
            self.setGeometry(screen.availableGeometry())
        self.caption.update()
        self.update()

    def _apply_margins(self):
        if self.layout():
            # 内容区再往里缩 1 像素,把窗口那圈描边留出来:否则滚动时内容会画到描边上,像凸出去一样
            m = self.margin() + (1 if self.margin() else 0)
            self.layout().setContentsMargins(m, m, m, m)
        self._place_caption()

    def showEvent(self, e):
        super().showEvent(e)
        if not self._styled:
            self._styled = True
            hwnd = int(self.winId())
            style = _user32.GetWindowLongPtrW(hwnd, -16)
            # 只加最小化(任务栏点击可最小化/还原)和可缩放边框;不加最大化样式,避免系统接管最大化
            style |= 0x00020000 | (0x00040000 if self._resizable else 0)
            style &= ~0x00010000
            _user32.SetWindowLongPtrW(hwnd, -16, style)
            _user32.SetWindowPos(hwnd, None, 0, 0, 0, 0, 0x0027)  # NOMOVE|NOSIZE|NOZORDER|FRAMECHANGED
        self._apply_margins()

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self._place_caption()

    def changeEvent(self, e):
        super().changeEvent(e)
        if hasattr(self, "caption"):
            self.caption.update()  # 失焦时按钮图标变灰

    def _place_caption(self):
        r = self.content_rect()
        self.caption.move(r.right() + 1 - self.caption.width(), r.top())
        self.caption.raise_()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.content_rect())
        rad = self.radius()
        m = self.margin()
        if m:
            # 柔和阴影:由外向内逐圈加深,整体略向下偏
            p.setPen(Qt.NoPen)
            for i in range(m, 0, -1):
                a = int(22 * ((m - i + 1) / m) ** 2)
                p.setBrush(C("shadow", a))
                p.drawRoundedRect(r.adjusted(-i, -i + 3, i, i + 3), rad + i, rad + i)
        surface = paint_window_surface(p, r, rad)
        p.setBrush(Qt.NoBrush)
        p.setPen(QPen(C("win_border"), 1) if m else Qt.NoPen)
        p.drawPath(surface)

    def _interactive_at(self, x, y):
        w = self.childAt(x, y)
        while w is not None and w is not self:
            if isinstance(w, (QAbstractButton, QLineEdit, QComboBox, QSlider, QPlainTextEdit, Segmented, CaptionButtons)):
                return True
            w = w.parentWidget()
        return False

    def mouseDoubleClickEvent(self, e):
        # 最大化状态下顶部不再交给系统拖动,双击顶部空白在这里还原
        pos = e.position().toPoint()
        if pos.y() - self.margin() < CAPTION_H and not self._interactive_at(pos.x(), pos.y()):
            self.toggle_maximized()

    def nativeEvent(self, event_type, message):
        if event_type != b"windows_generic_MSG":
            return False, 0
        msg = wintypes.MSG.from_address(int(message))
        m = msg.message
        if m == WM_NCCALCSIZE and msg.wParam:
            return True, 0  # 不要系统边框和标题栏,整个窗口都是内容区
        if m == WM_NCHITTEST:
            x = ctypes.c_short(msg.lParam & 0xFFFF).value
            y = ctypes.c_short((msg.lParam >> 16) & 0xFFFF).value
            wr = wintypes.RECT()
            _user32.GetWindowRect(msg.hWnd, ctypes.byref(wr))
            dpr = self.devicePixelRatioF()
            lx, ly = (x - wr.left) / dpr, (y - wr.top) / dpr
            w, h, mg = self.width(), self.height(), self.margin()
            if not self._max:
                band = mg + RESIZE_EDGE / 2
                left, right = lx < band, lx >= w - band
                top, bottom = ly < band, ly >= h - band
                if self._resizable:
                    corner = mg + 14  # 圆角处放宽,方便斜向拖动
                    cl, cr = lx < corner, lx >= w - corner
                    ct, cb = ly < corner, ly >= h - corner
                    for cond, code in (((top and cl) or (ct and left), HTTOPLEFT),
                                       ((top and cr) or (ct and right), HTTOPRIGHT),
                                       ((bottom and cl) or (cb and left), HTBOTTOMLEFT),
                                       ((bottom and cr) or (cb and right), HTBOTTOMRIGHT),
                                       (left, HTLEFT), (right, HTRIGHT), (top, HTTOP), (bottom, HTBOTTOM)):
                        if cond:
                            return True, code
                elif lx < mg or ly < mg or lx >= w - mg or ly >= h - mg:
                    return True, 0  # 不能缩放的窗口:阴影处不响应
            pos = QPointF(lx, ly).toPoint()
            if not self._max and ly - mg < CAPTION_H and not self._interactive_at(pos.x(), pos.y()):
                return True, HTCAPTION
            return True, HTCLIENT
        if m == WM_NCLBUTTONDBLCLK and msg.wParam == HTCAPTION:
            self.toggle_maximized()
            return True, 0
        return False, 0


# ---------- 基础控件 ----------
class GlassBackground(QWidget):
    """窗口内容的容器;底色和圆角由 ImmersiveWindow 自己画,这里透明。"""


def paint_window_surface(p, rect, radius):
    """窗口及顶部渐隐带共用同一表面,避免滚动区顶部出现纯色接缝。"""
    r = QRectF(rect)
    surface = QPainterPath()
    surface.addRoundedRect(r.adjusted(0.5, 0.5, -0.5, -0.5), radius, radius)
    p.save()
    p.setClipPath(surface)
    p.fillPath(surface, C("window"))
    # 夜色使用不透明纯色,避免淡彩径向渐变造成色带/纹理感。
    if THEME == "dark":
        p.restore()
        return surface
    for x, y, role in ((0.05, 0.05, "ambient_lilac"), (0.72, 0.94, "ambient_mint"),
                       (1.0, 0.0, "ambient_peach")):
        glow = QRadialGradient(QPointF(r.left() + r.width() * x, r.top() + r.height() * y),
                               max(r.width(), r.height()) * 0.8)
        glow.setColorAt(0, C(role))
        glow.setColorAt(1, C(role, 0))
        p.fillRect(r, glow)
    p.restore()
    return surface


def paint_card(p, rect, radius=12, fill=None, border=None, shadow=True):
    """薄玻璃表面:珍珠白渐变、细亮边和柔和底影,编辑区保持可读。"""
    p.setRenderHint(QPainter.Antialiasing)
    rect = QRectF(rect)
    if shadow:
        p.setPen(Qt.NoPen)
        p.setBrush(C("shadow", 16))
        p.drawRoundedRect(rect.adjusted(0, 1.5, 0, 1.5), radius, radius)
    gradient = QLinearGradient(rect.topLeft(), rect.bottomRight())
    if fill is None:
        gradient.setColorAt(0, C("card_top"))
        gradient.setColorAt(1, C("card_bottom"))
    else:
        gradient.setColorAt(0, fill.lighter(103))
        gradient.setColorAt(1, fill)
    p.setBrush(gradient)
    p.setPen(QPen(border or CARD_BORDER, 1))
    p.drawRoundedRect(rect.adjusted(0.5, 0.5, -0.5, -0.5), radius, radius)
    p.setBrush(Qt.NoBrush)
    p.setPen(QPen(C("surface_highlight"), 0.8))
    p.drawRoundedRect(rect.adjusted(1.5, 1.5, -1.5, -1.5), max(0, radius - 1), max(0, radius - 1))


class Card(QFrame):
    def __init__(self, *widgets, spacing=10, margins=(20, 16, 20, 16)):
        super().__init__()
        self.lay = QVBoxLayout(self)
        self.lay.setSpacing(spacing)
        self.lay.setContentsMargins(*margins)
        for w in widgets:
            self.add(w)

    def add(self, w):
        if isinstance(w, QWidget):
            self.lay.addWidget(w)
        else:
            self.lay.addLayout(w)

    def paintEvent(self, _e):
        p = QPainter(self)
        paint_card(p, self.rect().adjusted(1, 1, -1, -3))


class Toggle(QAbstractButton):
    """Windows 蓝色开关,保留珍珠白滑块,尺寸与原版一致。"""

    def __init__(self, checked=False):
        super().__init__()
        self.setCheckable(True)
        self.setChecked(checked)
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedSize(44, 22)
        self._progress = 1.0 if checked else 0.0
        self._slide = QVariantAnimation(self)
        self._slide.setDuration(140)
        self._slide.setEasingCurve(QEasingCurve.OutCubic)
        self._slide.valueChanged.connect(self._advance)
        self.toggled.connect(self._animate)

    def _animate(self, checked):
        self._slide.stop()
        self._slide.setStartValue(self._progress)
        self._slide.setEndValue(1.0 if checked else 0.0)
        self._slide.start()

    def _advance(self, value):
        self._progress = float(value)
        self.update()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(1, 1, 42, 20)
        # 页面加载会屏蔽 toggled 信号;非动画时仍以真实勾选状态定位滑块。
        if self._slide.state() != QAbstractAnimation.Running:
            self._progress = 1.0 if self.isChecked() else 0.0
        hover = self.underMouse()
        if self.isChecked():
            top = C("toggle_on_top")
            if hover:
                top = top.lighter(105)
            track = QLinearGradient(r.topLeft(), r.bottomLeft())
            track.setColorAt(0, top)
            track.setColorAt(1, C("toggle_on_bottom"))
            p.setPen(QPen(C("toggle_on_border"), 1))
            p.setBrush(track)
        else:
            p.setPen(QPen(C("toggle_off") if self.isEnabled() else C("glyph_disabled"), 1))
            p.setBrush(C("toggle_off_hover") if hover else C("toggle_off_bg"))
        knob = QRectF(3 + 22 * self._progress, 3, 16, 16)
        p.drawRoundedRect(r, 10, 10)
        p.setPen(Qt.NoPen)
        p.setBrush(C("shadow", 32))
        p.drawEllipse(knob.translated(0, 0.7))
        pearl = QLinearGradient(knob.topLeft(), knob.bottomLeft())
        pearl.setColorAt(0, C("knob_on"))
        pearl.setColorAt(1, C("knob_bottom"))
        p.setBrush(pearl)
        p.setPen(QPen(C("knob_border"), 0.7))
        p.drawEllipse(knob)

    def enterEvent(self, e):
        self.update()

    def leaveEvent(self, e):
        self.update()

    def sizeHint(self):
        return QSize(44, 22)


class Segmented(QWidget):
    """分段选择:选中项是一块白色玻璃。"""
    changed = Signal(str)

    def __init__(self, options, current, px=13, recommended=None):
        super().__init__()
        self.options = list(options.items())
        self.current = current
        self.px = px
        self.recommended = recommended
        self.setFixedHeight(36)
        self.setCursor(Qt.PointingHandCursor)
        self.setMinimumWidth(len(self.options) * 64)

    def set_current(self, key):
        self.current = key
        self.update()

    def _index_at(self, x):
        return min(len(self.options) - 1, max(0, int(x / (self.width() / len(self.options)))))

    def mousePressEvent(self, e):
        key = self.options[self._index_at(e.position().x())][0]
        if key != self.current:
            self.current = key
            self.update()
            self.changed.emit(key)

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(C("seg_border"), 1))
        p.setBrush(C("seg_bg"))
        p.drawRoundedRect(r, 10, 10)
        w = r.width() / len(self.options)
        for i, (key, text) in enumerate(self.options):
            cell = QRectF(r.left() + i * w, r.top(), w, r.height())
            if key == self.current:
                paint_card(p, cell.adjusted(3, 3, -3, -3), 8, C("seg_sel"), C("seg_sel_border"))
                p.setFont(font(self.px, QFont.DemiBold))
                p.setPen(TEXT)
            else:
                p.setFont(font(self.px))
                p.setPen(C("seg_text"))
            title = cell.adjusted(0, 6 if key == self.recommended else 0, 0, -1)
            p.drawText(title, Qt.AlignCenter, text)
            if key == self.recommended:
                badge = QRectF(cell.right() - 31, cell.top() + 3, 26, 12)
                p.setPen(Qt.NoPen)
                p.setBrush(C("toggle_on_bottom"))
                p.drawRoundedRect(badge, 4, 4)
                p.setPen(C("knob_on"))
                p.setFont(font(8, QFont.DemiBold))
                p.drawText(badge, Qt.AlignCenter, "推荐")


class ThemeSwitch(QWidget):
    """外观选择:小胶囊里三个图标——显示器(跟随系统)/ 太阳(浅色)/ 月亮(深色),选中的高亮。"""
    changed = Signal(str)
    ITEMS = [("system", "", "跟随系统"), ("light", "", "浅色"), ("dark", "", "深色")]
    CW, CH = 32, 28

    def __init__(self, current="system"):
        super().__init__()
        self.current = current
        self.hover = None
        self.setMouseTracking(True)
        self.setCursor(Qt.PointingHandCursor)
        self.setFixedSize(self.CW * len(self.ITEMS) + 6, self.CH + 6)

    def set_current(self, key):
        self.current = key
        self.update()

    def _index_at(self, x):
        i = int((x - 3) // self.CW)
        return i if 0 <= i < len(self.ITEMS) else None

    def mouseMoveEvent(self, e):
        i = self._index_at(e.position().x())
        if i != self.hover:
            self.hover = i
            self.setToolTip(self.ITEMS[i][2] if i is not None else "")
            self.update()

    def leaveEvent(self, e):
        self.hover = None
        self.update()

    def mousePressEvent(self, e):
        i = self._index_at(e.position().x())
        if i is not None and self.ITEMS[i][0] != self.current:
            self.current = self.ITEMS[i][0]
            self.update()
            self.changed.emit(self.current)

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(QPen(C("seg_border"), 1))
        p.setBrush(C("seg_bg"))
        p.drawRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 8, 8)
        f = QFont(ICON_FONT)
        f.setPixelSize(14)
        p.setFont(f)
        for i, (key, glyph, _tip) in enumerate(self.ITEMS):
            cell = QRectF(3 + i * self.CW, 3, self.CW, self.CH)
            if key == self.current:
                paint_card(p, cell.adjusted(1, 1, -1, -1), 6, C("seg_sel"), C("seg_sel_border"), shadow=False)
                p.setPen(TEXT)
            else:
                if i == self.hover:
                    p.setPen(Qt.NoPen)
                    p.setBrush(C("tint", 12))
                    p.drawRoundedRect(cell.adjusted(1, 1, -1, -1), 6, 6)
                p.setPen(SECONDARY)
            p.drawText(cell, Qt.AlignCenter, glyph)


class ComboBox(QComboBox):
    """下拉框:右侧画向下箭头,让人一眼看出能展开选择;鼠标滚轮不切换选项(交给页面滚动),
    避免滚动页面时不小心把选项换掉。"""

    def __init__(self):
        super().__init__()
        self.setFocusPolicy(Qt.StrongFocus)
        self.setCursor(Qt.PointingHandCursor)

    def wheelEvent(self, e):
        e.ignore()

    def paintEvent(self, e):
        super().paintEvent(e)
        p = QPainter(self)
        f = QFont(ICON_FONT)
        f.setPixelSize(13)
        p.setFont(f)
        p.setPen(C("seg_text") if self.isEnabled() else C("glyph_disabled"))
        p.drawText(QRect(self.width() - 32, 0, 24, self.height()), Qt.AlignCenter, "")  # ChevronDown


def row(title, control, subtitle=""):
    """卡片里的一行:左边标题(和说明),右边控件。"""
    box = QHBoxLayout()
    box.setSpacing(12)
    left = QVBoxLayout()
    left.setSpacing(3)
    left.addWidget(label(title, 14.5, CONTROL))
    if subtitle:
        left.addWidget(note(subtitle))
    box.addLayout(left, 1)
    if isinstance(control, QWidget):
        box.addWidget(control, 0, Qt.AlignVCenter)
    else:
        box.addLayout(control)
    return box


def button(text, slot=None, prominent=False, flat=False):
    b = QPushButton(text)
    b.setCursor(Qt.PointingHandCursor)
    if prominent:
        b.setProperty("prominent", "true")
    if flat:
        b.setProperty("flat", "true")
    if slot:
        b.clicked.connect(slot)
    return b


def scroll(widget, show_bar=False):
    area = QScrollArea()
    area.setWidgetResizable(True)
    area.setFrameShape(QFrame.NoFrame)
    area.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
    area.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded if show_bar else Qt.ScrollBarAlwaysOff)
    area.setWidget(widget)
    return area


def page(title):
    """右侧页面:大标题 + 内容。返回 (页面控件, 内容布局)。"""
    w = QWidget()
    lay = QVBoxLayout(w)
    lay.setContentsMargins(30, TITLE_TOP, 26, 24)
    lay.setSpacing(12)
    lay.addWidget(label(title, 25, TITLE, QFont.DemiBold))
    return w, lay


def section(text):
    s = label(text, 14, SECTION, QFont.DemiBold)
    s.setContentsMargins(4, 8, 0, 0)
    return s


# ---------- 录音胶囊 ----------
class Overlay(QWidget):
    """160×40 的白色玻璃胶囊,不抢焦点、平时鼠标可穿透。
    状态:录音(蓝色麦克风 + 波形)/ 识别中(灰色加载圈)/ 出错 / 已复制全文 / 提示 /
    learn_ask 询问"记住 X?"(底部倒计时条,此时可以点击)/ learned 已加入词典。"""
    BARS = 17
    W, H = 160, 40
    clicked = Signal()

    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                            | Qt.WindowDoesNotAcceptFocus | Qt.WindowTransparentForInput)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self._state, self._text, self._hint = "idle", "", ""
        self._levels = deque([0.0] * self.BARS, maxlen=self.BARS)
        self._peak = self._smooth = 0.0
        self._phase = 0
        self._anchor = None
        self._progress = 1.0     # learn_ask 的倒计时条
        self._clickable = False
        self._timer = QTimer(self, interval=40, timeout=self._tick)
        self._hide_timer = QTimer(self, singleShot=True, timeout=self.hide)
        # 录音状态延迟显示,过滤 Ctrl+C 这类瞬间误触
        self._show_timer = QTimer(self, singleShot=True, interval=round(engine.CUE_DELAY * 1000), timeout=self._show_now)
        self.resize(self.W + 16, self.H + 16)

    def set_anchor(self, anchor):
        self._anchor = anchor

    def set_state(self, state, text=""):
        if state == "recording" and self._state == "recording":
            return  # 录音中切到单击模式等只是提示变化,胶囊保持不动
        self._hide_timer.stop()
        self._show_timer.stop()
        self._state, self._text, self._hint = state, text, ""
        self._set_clickable(state == "learn_ask")
        if state == "idle":
            self._timer.stop()
            self.hide()
            return
        if state == "recording":
            self._levels = deque([0.0] * self.BARS, maxlen=self.BARS)
            self._peak = self._smooth = 0.0
            self._timer.start()
            self._show_timer.start()
            return
        if state == "copied":
            self._text = "输入中断 · 已复制全文" if text == "partial" else "已复制全文"
            self._hint = "按 Ctrl+V 手动粘贴"
            self._hide_timer.start(5000)
        elif state == "error":
            self._text = text or "出错了"
            self._hide_timer.start(2500)
        elif state == "notice":
            self._hide_timer.start(3000)
        elif state == "learn_ask":
            self._text = f"记住 {text}？"
            self._hint = "Ctrl+Enter 或点一下"
            self._progress = 1.0
        elif state == "learned":
            words = text.split("\n")
            self._text = (f"已记住 {words[0]}" if len(words) == 1 else f"已加入词典 {'、'.join(words)}")[:40]
            self._hide_timer.start(1800)
        elif state == "processing":
            self._text = "识别中"
        self._show_now()

    def set_progress(self, value):
        self._progress = max(0.0, min(1.0, value))
        self.update()

    def _set_clickable(self, on):
        """询问"记住 X?"时胶囊要能点;其他状态鼠标穿透,不挡下面的窗口。"""
        if on == self._clickable:
            return
        self._clickable = on
        visible = self.isVisible()
        self.setWindowFlag(Qt.WindowTransparentForInput, not on)
        self.setCursor(Qt.PointingHandCursor if on else Qt.ArrowCursor)
        if visible:
            self.show()

    def mousePressEvent(self, e):
        if self._state == "learn_ask":
            self.clicked.emit()

    def push_level(self, value):
        # 音频回调频率高于刷新频率,这里只记录两帧之间的峰值
        self._peak = max(self._peak, value)

    def _content_width(self):
        if self._state in ("recording", "processing"):
            return self.W
        fm = QFontMetrics(font(12.5, QFont.DemiBold))
        w = fm.horizontalAdvance(self._text)
        if self._hint:
            w = max(w, QFontMetrics(font(10.5)).horizontalAdvance(self._hint))
        return max(self.W, min(460, w + 64))

    def _show_now(self):
        w = self._content_width()
        self.resize(w + 16, self.H + 16)
        self._place()
        self.show()
        self._timer.start()
        self.update()

    def _place(self):
        a = self._anchor or {}
        w, h = self.width() - 16, self.H
        pointer = to_logical(*a["pointer"]) if a.get("pointer") else None
        screen = (QGuiApplication.screenAt(pointer.toPoint()) if pointer else None) or QGuiApplication.primaryScreen()
        area = screen.availableGeometry()
        mode = a.get("mode", "window")
        x = y = None
        if mode == "window" and a.get("window"):
            l, t, r, b = a["window"]
            tl, br = to_logical(l, t), to_logical(r, b)
            screen = QGuiApplication.screenAt(QPointF((tl.x() + br.x()) / 2, (tl.y() + br.y()) / 2).toPoint()) or screen
            area = screen.availableGeometry()
            x = (tl.x() + br.x()) / 2 - w / 2
            y = br.y() + 56  # 窗口外下方 56
            if y + h > area.bottom() - 8:
                y = min(br.y(), area.bottom()) - 56 - h  # 放不下或全屏:窗口内侧底部
        elif mode == "cursor" and pointer:
            x = pointer.x() - w / 2
            y = pointer.y() + 56
            if y + h > area.bottom() - 8:
                y = pointer.y() - 56 - h  # 底部空间不足,翻到鼠标上方
        if x is None:
            x = area.center().x() - w / 2
            y = area.bottom() - 56 - h
        x = max(area.left() + 8, min(x, area.right() - w - 8))
        y = max(area.top() + 8, min(y, area.bottom() - h - 8))
        self.move(int(x) - 8, int(y) - 8)

    def _tick(self):
        self._phase = (self._phase + 1) % 100000
        target = self._peak if self._state == "recording" else 0.0
        self._peak = 0.0
        # 快起慢落,波形跟随说话音量
        self._smooth = target if target > self._smooth else self._smooth * 0.7 + target * 0.3
        self._levels.append(self._smooth)
        self.update()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        r = QRectF(8, 8, self.width() - 16, self.H)
        # 胶囊:白色半透明 + 白色亮边 + 轻投影
        for i, a in ((6, 10), (3, 14), (1, 18)):
            p.setPen(Qt.NoPen)
            p.setBrush(C("cap_shadow", a))
            p.drawRoundedRect(r.adjusted(-i / 2, i / 2, i / 2, i), 20 + i / 2, 20 + i / 2)
        g = QLinearGradient(r.topLeft(), r.bottomLeft())
        g.setColorAt(0, C("cap_top"))
        g.setColorAt(1, C("cap_bottom"))
        p.setBrush(g)
        p.setPen(QPen(C("cap_edge"), 1.2))
        p.drawRoundedRect(r, 20, 20)
        p.setPen(QPen(C("cap_inner"), 1))
        p.drawRoundedRect(r.adjusted(1.5, 1.5, -1.5, -1.5), 18.5, 18.5)
        cy = r.center().y()
        if self._state == "recording":
            self._draw_mic(p, r.left() + 24, cy, BLUE)
            hist = list(self._levels)
            center = self.BARS // 2
            p.setPen(Qt.NoPen)
            p.setBrush(BLUE)
            x0 = r.left() + 44
            for i in range(self.BARS):
                d = abs(i - center)
                v = hist[-1 - d] * (1 - d / (center + 4))
                wobble = 0.15 * (1 + math.sin(self._phase * 0.35 + i * 1.3)) / 2
                bh = max(3.0, (v + wobble * min(1, v * 4)) * 22)
                p.drawRoundedRect(QRectF(x0 + i * 5.6, cy - bh / 2, 2.6, bh), 1.3, 1.3)
        elif self._state == "processing":
            fm = QFontMetrics(font(12.5))
            total = 18 + 8 + fm.horizontalAdvance(self._text)
            left = r.center().x() - total / 2
            p.setPen(QPen(C("spin_track"), 2.2))
            p.drawEllipse(QRectF(left + 2, cy - 7, 14, 14))
            p.setPen(QPen(C("spin_head"), 2.2, Qt.SolidLine, Qt.RoundCap))
            p.drawArc(QRectF(left + 2, cy - 7, 14, 14), -self._phase * 40 * 16 % (360 * 16), 100 * 16)
            p.setFont(font(12.5))
            p.setPen(CONTROL)
            p.drawText(QRectF(left + 26, r.top(), total, r.height()), Qt.AlignVCenter | Qt.AlignLeft, self._text)
        else:
            color = {"error": CORAL, "copied": BLUE, "learn_ask": ACCENT, "learned": ACCENT}.get(self._state, C("notice"))
            icon_x = r.left() + 22
            p.setPen(Qt.NoPen)
            p.setBrush(color)
            if self._state == "copied":
                p.setPen(QPen(color, 1.8))
                p.setBrush(Qt.NoBrush)
                p.drawRoundedRect(QRectF(icon_x - 6, cy - 7, 12, 15), 2.5, 2.5)
                p.drawLine(QPointF(icon_x - 3, cy - 7), QPointF(icon_x - 3, cy - 9))
                p.drawLine(QPointF(icon_x - 3, cy - 9), QPointF(icon_x + 3, cy - 9))
                p.drawLine(QPointF(icon_x + 3, cy - 9), QPointF(icon_x + 3, cy - 7))
            else:
                p.drawEllipse(QRectF(icon_x - 8, cy - 8, 16, 16))
                p.setPen(QPen(QColor("white"), 2, Qt.SolidLine, Qt.RoundCap))
                if self._state == "error":
                    p.drawLine(QPointF(icon_x, cy - 4), QPointF(icon_x, cy + 1))
                    p.drawPoint(QPointF(icon_x, cy + 4))
                elif self._state == "learn_ask":  # 加号:加入词典
                    p.drawLine(QPointF(icon_x - 4, cy), QPointF(icon_x + 4, cy))
                    p.drawLine(QPointF(icon_x, cy - 4), QPointF(icon_x, cy + 4))
                elif self._state == "learned":  # 对勾
                    p.drawLine(QPointF(icon_x - 4, cy), QPointF(icon_x - 1, cy + 3))
                    p.drawLine(QPointF(icon_x - 1, cy + 3), QPointF(icon_x + 4, cy - 3))
                else:
                    p.drawPoint(QPointF(icon_x, cy - 4))
                    p.drawLine(QPointF(icon_x, cy - 1), QPointF(icon_x, cy + 4))
            text_rect = QRectF(icon_x + 16, r.top(), r.width() - 54, r.height())
            p.setPen(C("cap_text"))
            if self._hint:
                p.setFont(font(12, QFont.DemiBold))
                p.drawText(text_rect.adjusted(0, 4, 0, -r.height() / 2 + 2), Qt.AlignLeft | Qt.AlignVCenter, self._text)
                p.setFont(font(10.5))
                p.setPen(SECONDARY)
                p.drawText(text_rect.adjusted(0, r.height() / 2 - 2, 0, -4), Qt.AlignLeft | Qt.AlignVCenter, self._hint)
            else:
                p.setFont(font(12.5, QFont.DemiBold))
                p.drawText(text_rect, Qt.AlignLeft | Qt.AlignVCenter, self._text)
            if self._state == "learn_ask":  # 底部倒计时条,走完自动收起
                path = QPainterPath()
                path.addRoundedRect(r, 20, 20)
                p.setClipPath(path)
                p.setPen(Qt.NoPen)
                p.setBrush(ACCENT)
                p.drawRect(QRectF(r.left(), r.bottom() - 2.5, r.width() * self._progress, 2.5))

    @staticmethod
    def _draw_mic(p, x, cy, color):
        p.setPen(Qt.NoPen)
        p.setBrush(color)
        p.drawRoundedRect(QRectF(x - 3.5, cy - 9, 7, 12), 3.5, 3.5)
        p.setPen(QPen(color, 1.6, Qt.SolidLine, Qt.RoundCap))
        p.setBrush(Qt.NoBrush)
        p.drawArc(QRectF(x - 6.5, cy - 6, 13, 12), 180 * 16, 180 * 16)
        p.drawLine(QPointF(x, cy + 6), QPointF(x, cy + 9))


def to_logical(x, y):
    """Win32 物理像素坐标 → Qt 逻辑坐标(各屏幕缩放比例可能不同)。"""
    for s in QGuiApplication.screens():
        g, dpr = s.geometry(), s.devicePixelRatio()
        if g.x() <= x < g.x() + g.width() * dpr and g.y() <= y < g.y() + g.height() * dpr:
            return QPointF(g.x() + (x - g.x()) / dpr, g.y() + (y - g.y()) / dpr)
    dpr = QGuiApplication.primaryScreen().devicePixelRatio()
    return QPointF(x / dpr, y / dpr)


# ---------- 设置窗口 ----------
class SidebarItem(QAbstractButton):
    def __init__(self, icon, text):
        super().__init__()
        self.setCheckable(True)
        self.setCursor(Qt.PointingHandCursor)
        self.icon_pm = QPixmap(os.path.join(ASSETS, icon))
        self.text_ = text
        self.setFixedHeight(46)

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)
        box = QRectF(self.rect()).adjusted(2, 3, -2, -3)
        if self.isChecked():
            paint_card(p, box, 11, C("nav_sel"), C("nav_border"))
        elif self.underMouse():
            p.setPen(Qt.NoPen)
            p.setBrush(C("tint", 10))
            p.drawRoundedRect(box, 11, 11)
        if not self.icon_pm.isNull():
            p.drawPixmap(QRect(13, 7, 30, 30), self.icon_pm)
        p.setFont(font(14.5))
        p.setFont(font(14.5, QFont.DemiBold if self.isChecked() else QFont.Normal))
        p.setPen(TEXT)
        p.drawText(QRectF(52, 0, self.width() - 56, self.height() - 3), Qt.AlignVCenter | Qt.AlignLeft, self.text_)

    def enterEvent(self, e):
        self.update()

    def leaveEvent(self, e):
        self.update()


class Sidebar(QWidget):
    def paintEvent(self, _e):
        if THEME == "dark":
            return  # 夜色侧栏与窗口共用纯色底,不叠加淡彩渐变。
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        # 侧栏底色沿窗口左侧圆角裁剪,不能涂到透明阴影区。
        radius = max(0, self.window().radius() - 1)
        clip = QPainterPath()
        clip.addRoundedRect(QRectF(self.rect()).adjusted(0, 0, radius, 0), radius, radius)
        p.setClipPath(clip)
        tint = QLinearGradient(0, 0, self.width(), self.height())
        tint.setColorAt(0, C("brand_lilac"))
        tint.setColorAt(0.55, C("brand_mint"))
        tint.setColorAt(1, C("brand_peach"))
        p.fillRect(self.rect(), tint)


class BrandWordmark(QWidget):
    """直接绘制确认稿的 SVG 字形轮廓;不经过字体匹配或文字排版。"""
    def __init__(self):
        super().__init__()
        with open(os.path.join(ASSETS, "onemore-wordmark.svg"), "rb") as source:
            self._source = source.read()
        self._renderer = QSvgRenderer(self)
        self._color = None
        self.setFixedSize(112, 21)
        self.setAccessibleName(config.APP_NAME)
        self.setAccessibleDescription("品牌字标")
        self.setAttribute(Qt.WA_TransparentForMouseEvents)

    def paintEvent(self, _e):
        color = C("brand_text").name()
        if color != self._color:
            self._renderer.load(QByteArray(self._source.replace(b"#58616e", color.encode("ascii"))))
            self._color = color
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        self._renderer.render(p, QRectF(self.rect()))


class BrandHeader(QWidget):
    """单行 OneMore 字标与用途说明,配色随浅色/深色主题切换。"""
    def __init__(self):
        super().__init__()
        self.setFixedHeight(68)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(4, 6, 4, 6)
        layout.setSpacing(6)
        icon = QLabel()
        pm = make_icon_pixmap(112)
        pm.setDevicePixelRatio(2)
        icon.setPixmap(pm)
        icon.setFixedSize(56, 56)
        icon.setAccessibleName(config.APP_NAME + " 图标")
        layout.addWidget(icon)
        self.name = BrandWordmark()
        words = QVBoxLayout()
        words.setSpacing(3)
        words.setAlignment(Qt.AlignVCenter)
        words.addWidget(self.name)
        words.addWidget(note("又一个语音输入法", 12))
        layout.addLayout(words)
        layout.addStretch()


def _set_note(lab, text):
    lab.setText(text)
    lab.setVisible(bool(text))


class TopFade(QWidget):
    """右侧内容区顶部的渐隐带:内容往上滚时在这里淡出,不会顶到窗口边缘、不压在右上角按钮下面。
    不挡鼠标,下面的控件照常可点。"""
    SOLID = 22  # 这一段完全是窗口底色,往下渐变到透明

    def __init__(self, parent):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)

    def paintEvent(self, _e):
        win = self.parentWidget()
        dpr = self.devicePixelRatioF()
        layer = QPixmap(round(self.width() * dpr), round(self.height() * dpr))
        layer.setDevicePixelRatio(dpr)
        layer.fill(Qt.transparent)
        brush = QPainter(layer)
        brush.setRenderHint(QPainter.Antialiasing)
        brush.save()
        brush.translate(-self.x(), -self.y())
        paint_window_surface(brush, win.content_rect(), win.radius())
        brush.restore()
        brush.setCompositionMode(QPainter.CompositionMode_DestinationIn)
        g = QLinearGradient(0, 0, 0, self.height())
        g.setColorAt(0, C("window", 255))
        g.setColorAt(self.SOLID / max(1, self.height()), C("window", 255))
        g.setColorAt(1, C("window", 0))
        brush.fillRect(self.rect(), g)
        brush.end()
        p = QPainter(self)
        p.drawPixmap(0, 0, layer)


class SettingsWindow(ImmersiveWindow):
    """controller 需提供:cfg、engine、changed()(保存并应用)、set_autostart(on)、apply_appearance()。"""
    TABS = [("general", "keyboard.png", "通用"), ("service", "cloud.png", "模型配置"),
            ("dictionary", "dictionary.png", "个人词典"),
            ("audio", "microphone.png", "麦克风与提示音"), ("history", "history.png", "历史记录"),
            ("tools", "tools.png", "附带工具")]
    _check_done = Signal(str, str)

    def __init__(self, controller):
        super().__init__(resizable=True)
        self.ctl = controller
        self.setWindowTitle(f"设置 - {config.APP_NAME}")
        self.setWindowIcon(QIcon(make_icon_pixmap()))
        self.setStyleSheet(STYLE)
        self.set_content_minimum(820, 560)
        self.resize_content(860, 600)
        self._loading = False
        self._capturing = False

        bg = self._bg = GlassBackground(self)
        outer = QHBoxLayout(bg)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        side = Sidebar()
        side.setFixedWidth(206)
        sl = QVBoxLayout(side)
        # 字标处于图标/说明组合的上半部,整组上移以对齐右侧标题的可见上沿。
        sl.setContentsMargins(12, TITLE_TOP - 10, 12, 14)
        sl.setSpacing(6)
        sl.addWidget(BrandHeader())
        sl.addSpacing(12)
        self.stack = QStackedWidget()
        self.tab_buttons = {}
        group = QButtonGroup(self)
        for key, icon, text in self.TABS:
            b = SidebarItem(icon, text)
            b.clicked.connect(lambda _c=False, k=key: self.select(k))
            group.addButton(b)
            sl.addWidget(b)
            self.tab_buttons[key] = b
        sl.addStretch()
        version = label(f"v{config.APP_VERSION}", 11, SECONDARY)
        version.setContentsMargins(6, 0, 0, 0)
        sl.addWidget(version)
        outer.addWidget(side)
        outer.addWidget(self.stack, 1)
        self.fade = TopFade(self)
        self.stack.installEventFilter(self)  # 内容区布局变化后再摆渐隐带,窗口改尺寸那一刻布局还没更新
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.addWidget(bg)

        self.pages = {}
        self.pages["general"] = self._build_general()
        self.pages["service"] = self._build_service()
        self.pages["audio"] = self._build_audio()
        self.dictionary = DictionaryPane(controller)
        self.pages["dictionary"] = self.dictionary
        self.history = HistoryPane(controller)
        self.pages["history"] = self.history
        self.tools = ToolsPane(controller)
        self.pages["tools"] = self.tools
        for key, _i, _t in self.TABS:
            self.stack.addWidget(self.pages[key])
        self._recorder = ShortcutRecorder(self)
        self._recorder.finished.connect(self._on_hotkey)
        self._check_done.connect(self._on_check_done)
        self.load(controller.cfg)
        self.select("general")

    def closeEvent(self, e):
        self.cancel_hotkey_capture()
        self.dictionary.cancel_capture()
        self.tools.cancel_capture()
        super().closeEvent(e)

    def eventFilter(self, obj, e):
        if obj is self.stack and e.type() in (QEvent.Resize, QEvent.Move):
            self._place_caption()
        return super().eventFilter(obj, e)

    def _place_caption(self):
        # 渐隐带盖在右侧内容区顶部(到页面标题上沿为止),右上角按钮再叠在它上面
        if hasattr(self, "fade"):
            top_left = self.stack.mapTo(self, QPoint(0, 0))
            self.fade.setGeometry(top_left.x(), top_left.y(), self.stack.width(), TITLE_TOP)
            self.fade.raise_()
        super()._place_caption()

    def select(self, key):
        if key != "general":
            self.cancel_hotkey_capture()
        if key != "dictionary":
            self.dictionary.cancel_capture()
        if key != "tools":
            self.tools.cancel_capture()
        self.tab_buttons[key].setChecked(True)
        self.stack.setCurrentWidget(self.pages[key])
        if key == "history":
            self.history.refresh()
        if key == "dictionary":
            self.dictionary.refresh()
        if key == "audio":
            self._fill_mics()
        if key == "tools":
            self.tools.refresh()

    # ----- 通用 -----
    def _build_general(self):
        w, lay = page("通用")
        self.keycap = QLabel()
        self.keycap.setAlignment(Qt.AlignCenter)
        self.keycap.setMinimumWidth(150)
        self.keycap.setFont(font(13.5))
        self.keycap.setObjectName("keycap")
        self.hotkey_btn = button("更改", self._capture_hotkey)
        keys = QHBoxLayout()
        keys.setSpacing(10)
        keys.addWidget(self.keycap)
        keys.addWidget(self.hotkey_btn)
        self.hotkey_hint = note("")
        self.hotkey_hint.hide()  # 平时不显示,只在录入新快捷键时提示
        lay.addWidget(Card(row("快捷键", keys), self.hotkey_hint))

        self.mode = Segmented(MODES, "both")
        self.mode.changed.connect(lambda k: self._set("mode", k, self.mode_hint.setText(MODE_HINTS[k])))
        self.mode_hint = note("")
        lay.addWidget(Card(label("触发方式", 14.5, CONTROL), self.mode, self.mode_hint))

        self.mouse = Toggle()
        self.mouse.toggled.connect(lambda v: self._set("mouse_longpress", v))
        lay.addWidget(Card(row("输入框长按鼠标说话", self.mouse,
                               "在输入框里按住左键 0.5 秒开始，松开提交；录音中点一下右键，松开后自动发送")))
        self.strip = Toggle()
        self.strip.toggled.connect(lambda v: self._set("strip_trailing_punct", v))
        lay.addWidget(Card(row("去掉末尾标点", self.strip)))
        self.autostart = Toggle()
        self.autostart.toggled.connect(self._autostart_changed)
        lay.addWidget(Card(row("开机自动启动", self.autostart)))
        self.theme = ThemeSwitch(self.ctl.cfg.get("appearance", "system"))
        self.theme.changed.connect(self._appearance_changed)
        lay.addWidget(Card(row("外观", self.theme)))
        lay.addStretch()
        return scroll(w)

    def _capture_hotkey(self):
        if self._capturing:
            return
        self._capturing = True
        self.ctl.system_snip.suspend()
        self.ctl.engine.suspend_hotkey()
        self.ctl.learner.unregister_hotkey()
        self.keycap.setText("请按键…")
        self.hotkey_btn.setEnabled(False)
        _set_note(self.hotkey_hint, "按下新快捷键（可组合）后松开；按 Esc 取消")

        self._recorder.start()

    def _on_hotkey(self, name):
        if not self._capturing:
            return
        self._recorder.cancel()
        self._capturing = False
        self.hotkey_btn.setEnabled(True)
        _set_note(self.hotkey_hint, "")
        if name and name != "esc":
            try:
                self.ctl.cfg["hotkey"] = validate_candidate(self.ctl.cfg, name, "voice")
                self.ctl.changed()
            except ValueError as e:
                _set_note(self.hotkey_hint, str(e))
        self.ctl.engine.resume_hotkey()
        self.ctl.learner.register_hotkey()
        self.ctl.system_snip.resume()
        self.keycap.setText(hotkey_display(self.ctl.cfg["hotkey"]))

    def cancel_hotkey_capture(self):
        if not self._capturing:
            return
        self._recorder.cancel()
        self._capturing = False
        self.hotkey_btn.setEnabled(True)
        self.keycap.setText(hotkey_display(self.ctl.cfg["hotkey"]))
        _set_note(self.hotkey_hint, "")
        self.ctl.engine.resume_hotkey()
        self.ctl.learner.register_hotkey()
        self.ctl.system_snip.resume()

    def _appearance_changed(self, mode):
        self.ctl.cfg["appearance"] = mode
        self.ctl.changed()
        self.ctl.apply_appearance()

    def apply_theme(self):
        """切换外观后:重新套样式表,自绘部分全部重画。"""
        self.setStyleSheet(STYLE)
        for w in self.findChildren(QWidget):
            w.update()
        self.update()

    def _autostart_changed(self, on):
        if self._loading:
            return
        ok = self.ctl.set_autostart(on)
        if not ok:
            self._loading = True
            self.autostart.setChecked(not on)
            self._loading = False

    # ----- 模型配置 -----
    def _build_service(self):
        w, lay = page("模型配置")
        names = {k: v["name"] for k, v in config.PROVIDERS.items()}
        self.provider = Segmented(names, "volcano", px=12.5, recommended="volcano")
        self.provider.changed.connect(self._provider_changed)
        self.key = QLineEdit()
        self.key.setEchoMode(QLineEdit.Password)
        self.key.setPlaceholderText("粘贴 API Key")
        self.key.editingFinished.connect(self._store_provider)
        self.check_btn = button("测试连接", self._run_check)
        key_row = QHBoxLayout()
        key_row.addWidget(self.key, 1)
        key_row.addWidget(self.check_btn)
        self.check_result = note("")
        self.check_result.hide()
        self.model = ComboBox()
        self.model.activated.connect(lambda _i: self._store_provider())  # 只能从列表里选,不能手写模型名
        self.fast = Toggle()
        self.fast.toggled.connect(lambda v: self._set("volcano_fast", v))
        self.fast_row = QWidget()
        fr = row("Fast 低延迟", self.fast, "需先在火山方舟控制台开通对应模型的“低延迟”；未开通时会自动改用常规档。费用为常规档的 2 倍")
        fr.setContentsMargins(0, 0, 0, 0)
        self.fast_row.setLayout(fr)
        lay.addWidget(Card(label("识别服务", 14.5, CONTROL), self.provider, label("API Key", 14.5, CONTROL), key_row,
                           self.check_result, label("模型", 14.5, CONTROL), self.model, self.fast_row))

        self.prompt = QPlainTextEdit()
        self.prompt.setMinimumHeight(130)
        self.prompt.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._prompt_timer = QTimer(self, singleShot=True, interval=600, timeout=self._store_prompt)
        self.prompt.textChanged.connect(lambda: None if self._loading else self._prompt_timer.start())
        reset = button("恢复默认", self._reset_prompt, flat=True)
        head = QHBoxLayout()
        head.addWidget(label("提示词", 14.5, CONTROL))
        head.addStretch()
        head.addWidget(reset)
        lay.addWidget(Card(head, self.prompt))

        self.app_context = Toggle()
        self.app_context.toggled.connect(lambda v: self._set("app_context", v))
        self.shot = Toggle()
        self.shot.toggled.connect(self._screenshot_changed)
        ctx = Card(label("附带应用上下文", 14.5, CONTROL),
                   row("应用名与窗口标题", self.app_context),
                   row("窗口截图", self.shot))
        lay.addWidget(ctx)
        lay.addStretch()
        return scroll(w)

    def _provider_changed(self, key):
        self._store_provider()
        self.ctl.cfg["provider"] = key
        self.ctl.changed()
        self._load_provider()
        _set_note(self.check_result, "")

    def _load_provider(self):
        cfg = self.ctl.cfg
        key = cfg["provider"]
        p = cfg["providers"][key]
        self._loading = True
        self.provider.set_current(key)
        self.key.setText(p["api_key"])
        self.model.clear()
        for model_id, title in config.PROVIDERS[key]["models"].items():
            self.model.addItem(title, model_id)
        self.model.setCurrentIndex(max(0, self.model.findData(p["model"])))
        self.fast_row.setVisible(key == "volcano")
        self.fast.setChecked(cfg.get("volcano_fast", True))
        self._loading = False

    def _model_id(self):
        """下拉框显示的是友好名,取选中项对应的模型 id。"""
        return self.model.currentData()

    def _store_provider(self):
        if self._loading:
            return
        p = self.ctl.cfg["providers"][self.ctl.cfg["provider"]]
        new = {"api_key": self.key.text().strip(), "model": self._model_id() or p["model"]}
        if any(p.get(k) != v for k, v in new.items()):
            p.update(new)
            self.ctl.changed()

    def _run_check(self):
        self._store_provider()
        import copy
        trial = copy.deepcopy(self.ctl.cfg)
        if not config.active_provider(trial)[0]["api_key"]:
            _set_note(self.check_result, "请先填写 API Key")
            return
        self.check_btn.setEnabled(False)
        self.check_btn.setText("测试中…")
        _set_note(self.check_result, "正在用一句测试语音实际识别一次…")
        threading.Thread(target=lambda: self._check_done.emit(trial["provider"], engine.service_check(trial)),
                         daemon=True).start()

    def _on_check_done(self, provider, result):
        self.check_btn.setEnabled(True)
        self.check_btn.setText("测试连接")
        if provider == self.ctl.cfg["provider"]:
            _set_note(self.check_result, result)

    def _store_prompt(self):
        text = self.prompt.toPlainText().strip()
        if text and text != self.ctl.cfg["prompt"]:
            self._set("prompt", text)

    def _reset_prompt(self):
        self.prompt.setPlainText(config.DEFAULT_PROMPT)
        self._set("prompt", config.DEFAULT_PROMPT)

    def _screenshot_changed(self, on):
        if self._loading:
            return
        if on and not self.ctl.cfg.get("screenshot_consent"):
            box = QMessageBox(self)
            box.setWindowTitle("开启窗口截图")
            box.setText("开启后，每次录音开始时会截取当前窗口（截不到时截整个屏幕），和录音一起发送给识别服务，"
                        "帮助模型理解同音字和专有名词。\n\n截图会出现在历史记录里；只有部分模型支持，"
                        "会增加首字耗时和费用。确定开启吗？")
            box.setStandardButtons(QMessageBox.Ok | QMessageBox.Cancel)
            box.button(QMessageBox.Ok).setText("开启")
            box.button(QMessageBox.Cancel).setText("取消")
            if box.exec() != QMessageBox.Ok:
                self._loading = True
                self.shot.setChecked(False)
                self._loading = False
                return
            self.ctl.cfg["screenshot_consent"] = True
        self._set("window_screenshot", on)

    # ----- 麦克风与提示音 -----
    def _build_audio(self):
        w, lay = page("麦克风与提示音")
        self.mic_box = QVBoxLayout()
        self.mic_box.setSpacing(8)
        self.mic_group = QButtonGroup(self)
        self.mic_group.buttonClicked.connect(lambda b: self._set("device", b.property("device")))
        self.mic_using = note("")
        lay.addWidget(Card(label("麦克风选择", 14.5, CONTROL), self.mic_box, self.mic_using))

        self.sound = Toggle()
        self.sound.toggled.connect(lambda v: self._set("sound", v))
        self.style_ = Segmented(config.SOUND_STYLES, "bubble")
        self.style_.changed.connect(lambda k: (self._set("sound_style", k), self._preview()))
        self.volume = QSlider(Qt.Horizontal)
        self.volume.setFixedHeight(26)  # 圆点直径 20,留出上下空间,否则会被裁掉
        self.volume.setRange(0, 100)
        self.volume_label = label("85%", 12.5, SECONDARY)
        self.volume_label.setFixedWidth(40)
        self.volume.valueChanged.connect(self._volume_changed)
        self.volume.sliderReleased.connect(self._preview)
        vol = QHBoxLayout()
        vol.addWidget(label("音量", 13, CONTROL))
        vol.addWidget(self.volume, 1)
        vol.addWidget(self.volume_label)
        vol.addWidget(button("试听", self._preview))
        lay.addWidget(Card(row("提示音", self.sound), self.style_, vol))

        self.position = Segmented(config.OVERLAY_POSITIONS, "window")
        self.position.changed.connect(lambda k: self._set("overlay_position", k))
        lay.addWidget(Card(label("胶囊位置", 14.5, CONTROL), self.position))

        lay.addStretch()
        return scroll(w)

    def _fill_mics(self):
        while self.mic_box.count():
            item = self.mic_box.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        for b in self.mic_group.buttons():
            self.mic_group.removeButton(b)
        current = self.ctl.cfg["device"]
        for value, text in engine.mic_choices(self.ctl.engine, current):
            rb = QRadioButton(text)
            rb.setProperty("device", value)
            if not value:
                rb.setToolTip(engine.AUTO_HINT)
            rb.setChecked(value == current)
            rb.setCursor(Qt.PointingHandCursor)
            self.mic_group.addButton(rb)
            self.mic_box.addWidget(rb)
        self.mic_using.setText(f"正在使用：{self.ctl.engine.mic_name or '无可用麦克风'}")

    def _volume_changed(self, v):
        self.volume_label.setText(f"{v}%")
        if not self._loading:
            self._set("sound_volume", v / 100)

    def _preview(self):
        cfg = self.ctl.cfg

        def run():
            import time
            engine.play_cue(True, cfg["sound_style"], cfg["sound_volume"])
            time.sleep(0.7)
            engine.play_cue(False, cfg["sound_style"], cfg["sound_volume"])

        threading.Thread(target=run, daemon=True).start()

    # ----- 公共 -----
    def _set(self, key, value, _unused=None):
        if self._loading:
            return
        self.ctl.cfg[key] = value
        self.ctl.changed()

    def load(self, cfg):
        """从配置刷新所有控件(托盘里改了设置时也会调用)。"""
        self._loading = True
        self.keycap.setText(hotkey_display(cfg["hotkey"]))
        self.mode.set_current(cfg.get("mode", "both"))
        self.mode_hint.setText(MODE_HINTS[cfg.get("mode", "both")])
        self.mouse.setChecked(cfg.get("mouse_longpress", False))
        self.strip.setChecked(cfg.get("strip_trailing_punct", True))
        self.autostart.setChecked(cfg.get("autostart", True))
        self.theme.set_current(cfg.get("appearance", "system"))
        if self.prompt.toPlainText() != cfg["prompt"]:
            self.prompt.setPlainText(cfg["prompt"])
        self.app_context.setChecked(cfg.get("app_context", True))
        self.shot.setChecked(cfg.get("window_screenshot", False))
        self.sound.setChecked(cfg.get("sound", True))
        self.style_.set_current(cfg.get("sound_style", "bubble"))
        self.volume.setValue(round(cfg.get("sound_volume", 0.85) * 100))
        self.volume_label.setText(f"{self.volume.value()}%")
        self.position.set_current(cfg.get("overlay_position", "window"))
        self._loading = False
        self._load_provider()
        self.tools.refresh()
        if self.stack.currentWidget() is self.pages.get("audio"):
            self._fill_mics()


# ---------- 附带工具 ----------
class ToolsPane(QWidget):
    _captured = Signal(int, str)

    def __init__(self, controller):
        super().__init__()
        self.ctl = controller
        self._capturing = False
        self._generation = 0
        self._cancel = None
        self._capture_index = None
        w, lay = page("附带工具")
        self.enabled = Toggle()
        self.enabled.setAccessibleName("启用系统截图快捷键")
        self.enabled.toggled.connect(self._toggle)
        self.options = QWidget()
        self.options_layout = QVBoxLayout(self.options)
        self.options_layout.setContentsMargins(0, 0, 0, 0)
        self.options_layout.setSpacing(16)
        self.hint = note("")
        self.hint.hide()
        lay.addWidget(Card(row("系统截图", self.enabled, "调用 Windows 自带截图工具"),
                           self.options, self.hint, spacing=18))
        lay.addStretch()
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll(w, show_bar=True))
        self._captured.connect(self._finish_capture)
        self.refresh()

    def refresh(self):
        enabled = self.ctl.cfg.get("screenshot_tool_enabled", False)
        self.enabled.blockSignals(True)
        self.enabled.setChecked(enabled)
        self.enabled.blockSignals(False)
        self.enabled.setEnabled(not self._capturing)
        _clear_layout(self.options_layout)
        shortcuts = list(self.ctl.cfg.get("screenshot_hotkeys", []))
        if self._capturing and self._capture_index == len(shortcuts):
            shortcuts.append("")
        for index, shortcut in enumerate(shortcuts):
            keys = QHBoxLayout()
            keys.setSpacing(8)
            cap = QLabel("请按键…" if self._capturing and index == self._capture_index
                         else hotkey_display(shortcut))
            cap.setObjectName("keycap")
            cap.setFont(font(13.5))
            cap.setAlignment(Qt.AlignCenter)
            cap.setMinimumWidth(150)
            keys.addWidget(cap)
            change = button("更改", lambda _c=False, i=index: self._capture(i))
            change.setAccessibleName(f"更改截图快捷键 {index + 1}")
            keys.addWidget(change)
            remove = button("删除", lambda _c=False, i=index: self._remove(i), flat=True)
            remove.setAccessibleName(f"删除截图快捷键 {index + 1}")
            keys.addWidget(remove)
            self.options_layout.addLayout(row(f"快捷键 {index + 1}", keys))
        add_row = QHBoxLayout()
        add_row.addWidget(button("添加快捷键", lambda: self._capture(len(shortcuts))))
        add_row.addStretch()
        self.options_layout.addLayout(add_row)
        self.options.setVisible(enabled)
        self.options.setEnabled(not self._capturing)
        if not self._capturing:
            _set_note(self.hint, "\n".join(self.ctl.system_snip.errors) if enabled else "")

    def _toggle(self, enabled):
        if enabled:
            probe = dict(self.ctl.cfg, screenshot_tool_enabled=True)
            try:
                for index, shortcut in enumerate(probe.get("screenshot_hotkeys", [])):
                    validate_candidate(probe, shortcut, "screenshot", index)
            except ValueError as e:
                self.refresh()
                _set_note(self.hint, str(e))
                return
        self.ctl.cfg["screenshot_tool_enabled"] = enabled
        self.ctl.changed()
        self.refresh()

    def _remove(self, index):
        shortcuts = list(self.ctl.cfg.get("screenshot_hotkeys", []))
        shortcuts.pop(index)
        self.ctl.cfg["screenshot_hotkeys"] = shortcuts
        self.ctl.changed()
        self.refresh()

    def _capture(self, index):
        if self._capturing:
            return
        self._capturing = True
        self._capture_index = index
        self._generation += 1
        generation = self._generation
        cancel = self._cancel = threading.Event()
        self.ctl.system_snip.suspend()
        self.ctl.engine.suspend_hotkey()
        self.ctl.learner.unregister_hotkey()
        self.refresh()
        _set_note(self.hint, "按下组合键后松开，Esc 取消")

        def worker():
            try:
                name = read_sided_hotkey(cancel)
            except Exception:
                name = ""
            if not cancel.is_set():
                self._captured.emit(generation, name)

        threading.Thread(target=worker, daemon=True).start()

    def _finish_capture(self, generation, name):
        if generation != self._generation or not self._capturing:
            return
        index = self._capture_index
        error = ""
        if name and name != "esc":
            try:
                name = validate_candidate(self.ctl.cfg, name, "screenshot", index)
                shortcuts = list(self.ctl.cfg.get("screenshot_hotkeys", []))
                if index == len(shortcuts):
                    shortcuts.append(name)
                else:
                    shortcuts[index] = name
                self.ctl.cfg["screenshot_hotkeys"] = shortcuts
                self.ctl.changed()
            except ValueError as e:
                error = str(e)
        self.cancel_capture()
        self.refresh()
        if error:
            _set_note(self.hint, error)

    def cancel_capture(self):
        if not self._capturing:
            return
        self._capturing = False
        self._generation += 1
        self._cancel.set()
        self.ctl.engine.resume_hotkey()
        self.ctl.learner.register_hotkey()
        self.ctl.system_snip.resume()
        self.refresh()


# ---------- 历史记录 ----------
# ---------- 个人词典 ----------
class ChipArea(QWidget):
    """词条胶囊:自动换行排列,每个右侧有 ×。整块自绘,词条再多也不卡。
    设计规格见 _scratch/claude/dictionary-design/output/spec.md(Codex 出的设计稿)。"""
    removed = Signal(str)
    H, PAD, GAP, X_W = 28, 11, 8, 20  # 胶囊高度、左右内边距、间距、× 区域宽

    def __init__(self):
        super().__init__()
        self.entries = []
        self.fresh = set()      # 刚添加(或刚被提示已存在)的词条,短暂高亮
        self.hover = None       # (序号, 是否在 × 上)
        self._rects = []
        self.setMouseTracking(True)
        self._fresh_timer = QTimer(self, singleShot=True, interval=900, timeout=self._clear_fresh)

    def set_entries(self, entries, fresh=()):
        self.entries = list(entries)
        if fresh:
            self.fresh = {config.word_key(w) for w in fresh}
            self._fresh_timer.start()
        self._layout()
        self.update()

    def _clear_fresh(self):
        self.fresh = set()
        self.update()

    def _font(self):
        return font(13)

    def _layout(self):
        fm = QFontMetrics(self._font())
        x = y = 0
        width = max(120, self.width())
        self._rects = []
        for e in self.entries:
            w = fm.horizontalAdvance(e["word"]) + self.PAD + self.X_W + 8
            w = min(w, width)
            if x > 0 and x + w > width:
                x, y = 0, y + self.H + self.GAP
            self._rects.append(QRectF(x, y, w, self.H))
            x += w + self.GAP
        h = (y + self.H) if self.entries else 0
        self.setMinimumHeight(h)
        self.setMaximumHeight(max(h, 1))

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self._layout()

    def rect_at(self, pos):
        for i, r in enumerate(self._rects):
            if r.contains(pos):
                return i, pos.x() >= r.right() - self.X_W - 4
        return None

    def first_fresh_rect(self):
        for e, r in zip(self.entries, self._rects):
            if config.word_key(e["word"]) in self.fresh:
                return r
        return None

    def mouseMoveEvent(self, e):
        hit = self.rect_at(e.position())
        if hit != self.hover:
            self.hover = hit
            self.setCursor(Qt.PointingHandCursor if hit and hit[1] else Qt.ArrowCursor)
            if hit:
                ent = self.entries[hit[0]]
                src = config.SOURCES.get(ent.get("source", ""), "")
                tip = "，".join(x for x in (src, ent.get("app", ""), ent.get("added", "")[:16]) if x)
                self.setToolTip(tip)
            else:
                self.setToolTip("")
            self.update()

    def leaveEvent(self, e):
        self.hover = None
        self.update()

    def mousePressEvent(self, e):
        hit = self.rect_at(e.position())
        if hit and hit[1]:
            self.removed.emit(self.entries[hit[0]]["word"])

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setFont(self._font())
        fm = p.fontMetrics()
        for i, (e, r) in enumerate(zip(self.entries, self._rects)):
            hovered = self.hover is not None and self.hover[0] == i
            fresh = config.word_key(e["word"]) in self.fresh
            if hovered:
                bg, border, xcol = C("button_hover"), C("field_line"), TEXT
            elif fresh:
                bg, border, xcol = C("seg_sel"), ACCENT, ACCENT
            else:
                bg, border, xcol = C("seg_bg"), C("seg_sel_border"), SECONDARY
            p.setPen(QPen(border, 1))
            p.setBrush(bg)
            p.drawRoundedRect(r.adjusted(0.5, 0.5, -0.5, -0.5), self.H / 2, self.H / 2)
            text_rect = QRectF(r.left() + self.PAD, r.top(), r.width() - self.PAD - self.X_W - 8, r.height())
            p.setPen(TEXT)
            p.drawText(text_rect, Qt.AlignVCenter | Qt.AlignLeft,
                       fm.elidedText(e["word"], Qt.ElideRight, int(text_rect.width()) + 1))
            # ×:两条短线,悬停在 × 上时更粗
            cx, cy, a = r.right() - self.X_W / 2 - 4, r.center().y(), 3.6
            p.setPen(QPen(xcol, 1.8 if hovered and self.hover[1] else 1.3, Qt.SolidLine, Qt.RoundCap))
            p.drawLine(QPointF(cx - a, cy - a), QPointF(cx + a, cy + a))
            p.drawLine(QPointF(cx - a, cy + a), QPointF(cx + a, cy - a))


LEARN_MODES = {"ask": "每次询问", "auto": "第 2 次自动记住", "off": "关闭"}


class DictionaryPane(QWidget):
    """个人词典:添加(可一次粘贴多个)、自动去重、点 × 删除。词条在识别时加进提示词。
    另有"选中文字加入词典"快捷键和"从修改中学习"方式(与 Mac 一致)。"""

    def __init__(self, controller):
        super().__init__()
        self.ctl = controller
        self._capturing = False
        lay = QVBoxLayout(self)
        lay.setContentsMargins(30, TITLE_TOP, 26, 24)
        lay.setSpacing(12)
        lay.addWidget(label("个人词典", 25, TITLE, QFont.DemiBold))

        self.input = QLineEdit()
        self.input.setPlaceholderText("输入词条，回车添加；可一次粘贴多个，用逗号隔开")
        self.input.returnPressed.connect(self._add)
        add = button("添加", self._add, prominent=True)
        add.setMinimumWidth(78)
        add_row = QHBoxLayout()
        add_row.setSpacing(10)
        add_row.addWidget(self.input, 1)
        add_row.addWidget(add)
        self.feedback = note("")
        self.feedback.hide()
        lay.addWidget(Card(label("添加词条", 13.5, CONTROL), add_row, self.feedback, spacing=8))

        self.keycap = QLabel()
        self.keycap.setAlignment(Qt.AlignCenter)
        self.keycap.setMinimumWidth(130)
        self.keycap.setFont(font(13))
        self.keycap.setObjectName("keycap")
        self.hotkey_btn = button("更改", self._capture_hotkey)
        keys = QHBoxLayout()
        keys.setSpacing(10)
        keys.addWidget(self.keycap)
        keys.addWidget(self.hotkey_btn)
        self.hotkey_hint = note("")
        self.hotkey_hint.hide()
        self.learn = Segmented(LEARN_MODES, "ask")
        self.learn.setMinimumWidth(330)
        self.learn.changed.connect(self._learn_changed)
        lay.addWidget(Card(row("选中文字加入词典", keys), self.hotkey_hint, row("从修改中学习", self.learn), spacing=12))
        self._recorder = ShortcutRecorder(self)
        self._recorder.finished.connect(self._on_hotkey)

        self.count = label("", 13.5, CONTROL, QFont.DemiBold)
        line = QFrame()
        line.setFixedHeight(1)
        line.setObjectName("separator")
        self.chips = ChipArea()
        self.chips.removed.connect(self._remove)
        self.empty = label("还没有词条，添加常用名称吧。", 13, SECONDARY)
        self.empty.setAlignment(Qt.AlignCenter)
        holder = QWidget()
        hl = QVBoxLayout(holder)
        hl.setContentsMargins(0, 0, 4, 0)
        hl.addWidget(self.chips)
        hl.addStretch()
        self.area = scroll(holder, show_bar=True)
        self.area.setObjectName("chips")
        card = Card(self.count, line, self.area, self.empty, spacing=12, margins=(18, 14, 14, 18))
        card.lay.setStretch(2, 1)
        card.lay.setStretch(3, 1)
        lay.addWidget(card, 1)
        self._fb_timer = QTimer(self, singleShot=True, interval=2500, timeout=lambda: _set_note(self.feedback, ""))

    def refresh(self, fresh=()):
        cfg = self.ctl.cfg
        if not self._capturing:
            self.keycap.setText(hotkey_display(cfg.get("dictionary_hotkey", "")) or "未设置")
        self.learn.set_current(cfg.get("dictionary_learn", "ask"))
        entries = cfg.get("dictionary", [])
        self.count.setText(f"共 {len(entries)} 个词条")
        self.empty.setVisible(not entries)
        self.area.setVisible(bool(entries))
        self.chips.set_entries(entries, fresh)
        if fresh:
            QTimer.singleShot(0, self._reveal_fresh)

    def _reveal_fresh(self):
        r = self.chips.first_fresh_rect()
        if r is not None:
            self.area.ensureVisible(int(r.center().x()), int(r.center().y()), 0, 40)

    def _add(self):
        words = config.split_words(self.input.text())
        if not words:
            return
        added = config.add_words(self.ctl.cfg, words, source="manual")
        if added:
            self.ctl.changed()
        dup = len(words) - len(added)
        msg = f"已有 {dup} 个，已跳过" if dup and added else ("词典里已经有了" if dup else "")
        _set_note(self.feedback, msg)
        if msg:
            self._fb_timer.start()
        self.input.clear()
        self.refresh(fresh=words)  # 新加的高亮;已存在的也高亮一下,让人看到在哪

    def _remove(self, word):
        config.remove_word(self.ctl.cfg, word)
        self.ctl.changed()
        self.refresh()

    def _learn_changed(self, mode):
        self.ctl.cfg["dictionary_learn"] = mode
        self.ctl.changed()

    def _capture_hotkey(self):
        if self._capturing:
            return
        self._capturing = True
        self.ctl.engine.suspend_hotkey()
        self.ctl.learner.unregister_hotkey()
        self.ctl.system_snip.suspend()
        self.keycap.setText("请按键…")
        self.hotkey_btn.setEnabled(False)
        _set_note(self.hotkey_hint, "按下新快捷键（可组合）后松开；按 Esc 取消")

        self._recorder.start()

    def _on_hotkey(self, name):
        if not self._capturing:
            return
        self._recorder.cancel()
        error = ""
        if name and name != "esc":
            try:
                self.ctl.cfg["dictionary_hotkey"] = validate_candidate(self.ctl.cfg, name, "dictionary")
                self.ctl.changed()
            except ValueError as e:
                error = str(e)
        self.cancel_capture()
        _set_note(self.hotkey_hint, error)

    def cancel_capture(self):
        if self._capturing:
            self._recorder.cancel()
            self._capturing = False
            self.hotkey_btn.setEnabled(True)
            self.keycap.setText(hotkey_display(self.ctl.cfg.get("dictionary_hotkey", "")) or "未设置")
            _set_note(self.hotkey_hint, "")
            self.ctl.engine.resume_hotkey()
            self.ctl.learner.register_hotkey()
            self.ctl.system_snip.resume()


class ClickLabel(QLabel):
    clicked = Signal()

    def mousePressEvent(self, e):
        self.clicked.emit()


class HistoryPane(QWidget):
    """历史记录:耗时/费用、截图缩略图、长文折叠、播放(自动增强音量)、复制、重新识别。"""

    def __init__(self, controller):
        super().__init__()
        self.ctl = controller
        self.expanded = set()
        self.busy = set()
        self.playing = None
        self.tip_text = ""
        self._play_timer = QTimer(self, singleShot=True, timeout=self._play_done)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        self.body = QWidget()
        self.lay = QVBoxLayout(self.body)
        self.lay.setContentsMargins(30, TITLE_TOP, 22, 24)
        self.lay.setSpacing(10)
        self.area = scroll(self.body, show_bar=True)
        self.area.setObjectName("history")
        outer.addWidget(self.area)
        controller.engine.retry_done.connect(self._retry_done)

    def refresh(self):
        if not self.isVisible() and self.lay.count():
            self._dirty = True
            return
        self._dirty = False
        bar = self.area.verticalScrollBar().value()
        while self.lay.count():
            item = self.lay.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
            elif item.layout():
                _clear_layout(item.layout())
        cfg = self.ctl.cfg
        enabled, limit = cfg.get("history_enabled", True), cfg.get("history_limit", 100)
        items = config.load_history() if enabled else []
        title = QHBoxLayout()
        title.addWidget(label("历史记录", 25, TITLE, QFont.DemiBold))
        title.addStretch()
        sw = Toggle(enabled)
        sw.setToolTip("关闭后清空已有文字、录音和截图，后续不再保留历史")
        sw.toggled.connect(self._enabled_changed)
        title.addWidget(sw)
        self.lay.addLayout(title)
        head = QHBoxLayout()
        head.setSpacing(6)
        head.addWidget(note("仅在本地保存" if limit == 0 else "仅在本地保存最近"))
        combo = ComboBox()
        for n in config.HISTORY_LIMITS:
            combo.addItem("永久" if n == 0 else f"{n} 条", n)
        combo.setCurrentIndex(max(0, combo.findData(limit)))
        combo.setEnabled(enabled)
        combo.setToolTip("调小数量会立即删除超出的旧记录及其录音和截图")
        combo.activated.connect(lambda i: self._limit_changed(combo.itemData(i)))
        combo.setFixedWidth(124)  # 右侧留了箭头位置,"100 条"要完整显示
        head.addWidget(combo)
        head.addStretch()
        if self.tip_text:
            head.addWidget(note(self.tip_text))
        head.addWidget(button("打开录音文件夹", self._open_folder, flat=True))
        clear = button("清空", self._clear)
        clear.setEnabled(bool(items) and not self.busy)
        head.addWidget(clear)
        self.lay.addLayout(head)
        if not enabled:
            self.lay.addWidget(Card(label("历史记录已关闭", 14.5, CONTROL), note("后续不保留文字、录音和截图。")))
        elif not items:
            self.lay.addWidget(Card(label("还没有录音", 14.5, CONTROL), note("按下快捷键开始说话，记录会出现在这里。")))
        for e in items:
            self.lay.addWidget(self._card(e))
        self.lay.addStretch()
        QTimer.singleShot(0, lambda: self.area.verticalScrollBar().setValue(bar))

    def showEvent(self, e):
        super().showEvent(e)
        if getattr(self, "_dirty", True):
            self.refresh()

    def _card(self, e):
        rid = e.get("id", "")
        failed = e.get("status") == "failed" and not e.get("text")
        when = e.get("time", "")[5:16]
        app = e.get("app", "").split("（")[0]
        card = Card(spacing=6, margins=(18, 12, 18, 14))
        card.add(label(when + (f" · {app}" if app else ""), 12, SECONDARY))
        text = e.get("text") or (e.get("error") if failed else "暂无识别结果")
        if rid in self.busy:
            text = "重新识别中…"
        body = QLabel(text)
        body.setWordWrap(True)
        body.setTextInteractionFlags(Qt.TextSelectableByMouse)
        body.setFont(font(14))
        if failed:
            body.setProperty("tone", "error")
        foldable = len(text) > 100 or text.count("\n") >= 4
        line = QHBoxLayout()
        line.addWidget(body, 1)
        if foldable:
            opened = rid in self.expanded
            if not opened:
                body.setMaximumHeight(QFontMetrics(body.font()).lineSpacing() * 4 + 4)
            fold = button("收起" if opened else "展开", lambda _c=False, r=rid: self._toggle_fold(r), flat=True)
            line.addWidget(fold, 0, Qt.AlignTop)
        card.add(line)
        st = e.get("stats") or {}
        # 旧历史仍展示原服务名，但不把已移除的节点放回可选列表。
        provider_name = ("百炼·新加坡（已移除）" if e.get("provider") == "bailian"
                         else config.PROVIDERS.get(e.get("provider", ""), {}).get("name", ""))
        tier = ""
        if st.get("fast_fallback"):
            tier = " · 常规（Fast 未开通）"
        elif st.get("service_tier") == "fast":
            tier = " · Fast"
        model = config.model_title(e.get("provider", ""), e.get("model", ""))
        meta = " · ".join(x for x in (("带截图" if e.get("screenshot") else ""), model + tier, provider_name) if x)
        info = QVBoxLayout()
        info.setSpacing(3)
        info.addWidget(label(meta, 11.5, SECONDARY))
        if st:
            first = f"{st['first']:.2f} s" if st.get("first") is not None else "—"
            total = f"{st['total']:.2f} s" if st.get("total") is not None else "—"
            cost = cost_text(st.get("cost"))
            share = ""
            if e.get("screenshot"):
                if st.get("image_cost") is not None and st.get("cost"):
                    pct = st["image_cost"] / st["cost"] * 100
                    share = "<1%" if 0 < pct < 1 else f"{pct:.0f}%"
                share = f"（截图占比 {share or '—'}）"
            timing = label(f"首字 {first}  ·  总耗时 {total}  ·  预估 {cost}{share}", 11.5, SECONDARY)
            origin = "点击重新识别" if st.get("retried") else "结束录音"
            timing.setToolTip(f"首字：从{origin}到首次收到有效文字；总耗时：从{origin}到完整结果接收完毕。\n"
                              + st.get("pricing_note", ""))
            info.addWidget(timing)
        if e.get("screenshot_note"):
            info.addWidget(note(e["screenshot_note"], 11))
        if e.get("error") and not failed:
            info.addWidget(label(e["error"], 11, CORAL, wrap=True))
        bottom = QHBoxLayout()
        bottom.addLayout(info, 1)
        shot = config.screenshot_path(e)
        if shot and os.path.exists(shot):
            thumb = ClickLabel()
            pm = QPixmap(shot)
            thumb.setPixmap(pm.scaled(64, 40, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation).copy(0, 0, 64, 40))
            thumb.setFixedSize(64, 40)
            thumb.setCursor(Qt.PointingHandCursor)
            thumb.setToolTip(f"查看提交的截图（{os.path.getsize(shot) / 1024:.0f} KB）")
            thumb.setObjectName("thumb")
            thumb.clicked.connect(lambda p=shot: self._show_image(p))
            bottom.addWidget(thumb, 0, Qt.AlignBottom)
        card.add(bottom)
        actions = QHBoxLayout()
        actions.setSpacing(8)
        audio = config.recording_path(e)
        has_audio = bool(audio and os.path.exists(audio))
        play = button("停止" if self.playing == rid else "播放", lambda _c=False, x=e: self._play(x))
        play.setEnabled(has_audio)
        copy_btn = button("复制", lambda _c=False, t=e.get("text", ""): self._copy(t))
        copy_btn.setEnabled(bool(e.get("text")))
        retry = button("重新识别", lambda _c=False, x=e: self._retry(x))
        retry.setEnabled(has_audio and rid not in self.busy)
        retry.setToolTip("用当前选中的识别服务重新识别这条录音（沿用当时的程序信息和截图）")
        for b in (play, copy_btn, retry):
            actions.addWidget(b)
        actions.addStretch()
        card.add(actions)
        return card

    def _toggle_fold(self, rid):
        self.expanded ^= {rid}
        self.refresh()

    def _show_image(self, path):
        dlg = QDialog(self)
        dlg.setWindowTitle("提交的截图")
        lay = QVBoxLayout(dlg)
        lab = QLabel()
        pm = QPixmap(path)
        avail = QGuiApplication.primaryScreen().availableGeometry()
        lab.setPixmap(pm.scaled(min(pm.width(), avail.width() - 120), min(pm.height(), avail.height() - 160),
                                Qt.KeepAspectRatio, Qt.SmoothTransformation))
        lay.addWidget(lab)
        dlg.exec()

    def _play(self, e):
        rid = e["id"]
        import sounddevice as sd
        if self.playing == rid:
            sd.stop()
            self._play_done()
            return
        try:
            import soundfile as sf
            path = config.recording_path(e)
            duration = sf.info(path).duration
            engine.play_file(path)
            self.playing = rid
            self._play_timer.start(int(duration * 1000) + 300)
        except Exception as ex:
            self.tip_text = f"播放失败：{ex}"
        self.refresh()

    def _play_done(self):
        self.playing = None
        self.refresh()

    def _copy(self, text):
        QGuiApplication.clipboard().setText(text)
        self.tip_text = "已复制"
        self.refresh()
        QTimer.singleShot(1500, self._clear_tip)

    def _clear_tip(self):
        self.tip_text = ""
        self.refresh()

    def _retry(self, e):
        if not config.active_provider(self.ctl.cfg)[0]["api_key"]:
            self.tip_text = "请先在模型配置里填写 API Key"
            self.refresh()
            return
        self.busy.add(e["id"])
        self.ctl.engine.retranscribe(e)
        self.refresh()

    def _retry_done(self, rid, text, error):
        self.busy.discard(rid)
        self.tip_text = "重新识别完成" if text else f"重新识别失败：{error}"
        self.refresh()
        QTimer.singleShot(3000, self._clear_tip)

    def _open_folder(self):
        os.makedirs(config.RECORDINGS_DIR, exist_ok=True)
        os.startfile(config.RECORDINGS_DIR)

    def _confirm(self, title, text, ok):
        box = QMessageBox(self)
        box.setWindowTitle(title)
        box.setText(text)
        box.setStandardButtons(QMessageBox.Ok | QMessageBox.Cancel)
        box.button(QMessageBox.Ok).setText(ok)
        box.button(QMessageBox.Cancel).setText("取消")
        return box.exec() == QMessageBox.Ok

    def _clear_files(self):
        try:
            config.clear_history()
            return True
        except OSError:
            QMessageBox.warning(self, "未能清空全部文件", "部分文件无法删除，请关闭占用录音的程序后重试。历史开关保持不变。")
            return False

    def _clear(self):
        if self._confirm("清空历史", "确定清空全部历史记录、录音和截图吗？旧版保留的训练录音和文字索引也会删除。", "清空"):
            if not self._clear_files():
                return
            self.refresh()

    def _enabled_changed(self, on):
        if not on:
            if not self._confirm("关闭历史记录", "关闭后会清空已有的文字、录音、截图及旧版训练素材，后续也不再保留。", "关闭并清空"):
                self.refresh()
                return
            if not self._clear_files():
                self.refresh()
                return
        self.ctl.cfg["history_enabled"] = on
        self.ctl.changed()
        self.refresh()

    def _limit_changed(self, limit):
        self.ctl.cfg["history_limit"] = limit
        self.ctl.changed()
        config.apply_history_limit(limit)
        self.refresh()


def _clear_layout(lay):
    while lay.count():
        item = lay.takeAt(0)
        if item.widget():
            item.widget().deleteLater()
        elif item.layout():
            _clear_layout(item.layout())


# ---------- 首次引导 ----------
class Stepper(QWidget):
    def __init__(self, titles):
        super().__init__()
        self.titles = titles
        self.step = 1
        self.setFixedHeight(54)

    def set_step(self, step):
        self.step = step
        self.update()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        n = len(self.titles)
        w = self.width() / n
        for i, t in enumerate(self.titles):
            cx = w * i + w / 2
            if i < n - 1:
                p.setPen(QPen(C("step_line"), 1.5))
                p.drawLine(QPointF(cx + 18, 16), QPointF(cx + w - 18, 16))
            done = i + 1 <= self.step
            p.setPen(QPen(C("step_active_border") if done else C("step_off"), 1.2))
            p.setBrush(C("step_active") if done else C("step_off_bg"))
            p.drawEllipse(QRectF(cx - 13, 3, 26, 26))
            p.setPen(C("accent_text") if done else SECONDARY)
            p.setFont(font(12.5, QFont.DemiBold))
            p.drawText(QRectF(cx - 13, 3, 26, 26), Qt.AlignCenter, str(i + 1))
            p.setFont(font(12, QFont.DemiBold if i + 1 == self.step else QFont.Normal))
            p.setPen(TEXT if i + 1 == self.step else SECONDARY)
            p.drawText(QRectF(cx - w / 2, 32, w, 20), Qt.AlignCenter, t)


class OnboardingWindow(ImmersiveWindow):
    """三步引导:选服务填 Key(可测试)→ 快捷键与触发方式 → 在框里试一次。"""
    finished = Signal()
    _check_done = Signal(str)

    def __init__(self, controller):
        super().__init__(resizable=False)
        self.ctl = controller
        self.setWindowTitle(f"欢迎使用 {config.APP_NAME}")
        self.setWindowIcon(QIcon(make_icon_pixmap()))
        self.setStyleSheet(STYLE)
        self.fix_content_size(820, 610)
        self.step = 1
        self._capturing = False
        bg = self._bg = GlassBackground(self)
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.addWidget(bg)
        outer = QHBoxLayout(bg)
        outer.addStretch()
        col = QVBoxLayout()
        col.setContentsMargins(0, CAPTION_H, 0, 22)
        col.setSpacing(14)
        center = QWidget()
        center.setFixedWidth(500)
        center.setLayout(col)
        outer.addWidget(center)
        outer.addStretch()
        brand = BrandHeader()
        brand.setFixedWidth(196)
        col.addWidget(brand, 0, Qt.AlignHCenter)
        self.stepper = Stepper(["识别服务", "快捷键", "试一试"])
        col.addWidget(self.stepper)
        self.title = label("", 25, TITLE, QFont.DemiBold)
        self.title.setAlignment(Qt.AlignCenter)
        self.subtitle = note("", 13)
        self.subtitle.setAlignment(Qt.AlignCenter)
        col.addWidget(self.title)
        col.addWidget(self.subtitle)
        self.pages = QStackedWidget()
        col.addWidget(self.pages, 1)

        # 第 1 步
        names = {k: v["name"] for k, v in config.PROVIDERS.items()}
        self.provider = Segmented(names, controller.cfg["provider"], px=12.5, recommended="volcano")
        self.provider.changed.connect(self._provider_changed)
        self.key = QLineEdit()
        self.key.setEchoMode(QLineEdit.Password)
        self.key.setPlaceholderText("粘贴 API Key")
        self.check_btn = button("测试连接", self._run_check)
        kr = QHBoxLayout()
        kr.addWidget(self.key, 1)
        kr.addWidget(self.check_btn)
        self.check_result = note("")
        self.check_result.hide()
        p1 = QWidget()
        l1 = QVBoxLayout(p1)
        l1.setContentsMargins(0, 0, 0, 0)
        l1.addWidget(Card(self.provider, label("API Key", 14, CONTROL), kr, self.check_result, spacing=12))
        l1.addWidget(note("模型和提示词，可稍后在「模型配置」中调整。"))
        l1.addStretch()
        self.pages.addWidget(p1)

        # 第 2 步
        self.keycap = QLabel(hotkey_display(controller.cfg["hotkey"]))
        self.keycap.setAlignment(Qt.AlignCenter)
        self.keycap.setFont(font(15))
        self.keycap.setMinimumHeight(46)
        self.keycap.setObjectName("keycap")
        self.hotkey_btn = button("更改", self._capture_hotkey)
        kc = QHBoxLayout()
        kc.addWidget(self.keycap, 1)
        kc.addWidget(self.hotkey_btn)
        self.mode = Segmented(MODES, controller.cfg.get("mode", "both"))
        self.mode_hint = note(MODE_HINTS[controller.cfg.get("mode", "both")])
        self.mode.changed.connect(self._mode_changed)
        p2 = QWidget()
        l2 = QVBoxLayout(p2)
        l2.setContentsMargins(0, 0, 0, 0)
        l2.addWidget(Card(label("快捷键", 14, CONTROL), kc, label("触发方式", 14, CONTROL), self.mode,
                          self.mode_hint, spacing=12))
        l2.addStretch()
        self.pages.addWidget(p2)

        # 第 3 步
        self.trial = QPlainTextEdit()
        self.trial.setPlaceholderText("点这里，然后按快捷键说一句话试试")
        self.trial.setMinimumHeight(150)
        p3 = QWidget()
        l3 = QVBoxLayout(p3)
        l3.setContentsMargins(0, 0, 0, 0)
        l3.addWidget(Card(self.trial))
        l3.addStretch()
        self.pages.addWidget(p3)

        nav = QHBoxLayout()
        nav.addWidget(button("跳过", self._finish, flat=True))
        nav.addStretch()
        self.back_btn = button("上一步", self._back)
        self.next_btn = button("下一步", self._next, prominent=True)
        self.next_btn.setMinimumWidth(110)
        nav.addWidget(self.back_btn)
        nav.addWidget(self.next_btn)
        col.addLayout(nav)
        self._recorder = ShortcutRecorder(self)
        self._recorder.finished.connect(self._on_hotkey)
        self._check_done.connect(self._on_check)
        self._load_key()
        self._show(1)

    def apply_theme(self):
        self.setStyleSheet(STYLE)
        for w in self.findChildren(QWidget):
            w.update()
        self.update()

    def _show(self, step):
        self.cancel_capture()
        self.step = step
        self.stepper.set_step(step)
        self.pages.setCurrentIndex(step - 1)
        self.title.setText(["连接识别服务", "设置快捷键", "试一试"][step - 1])
        self.subtitle.setText(["选择识别服务并填写 API Key，可以先测试一下", "按快捷键开始说话，结束后文字会打到光标处",
                               "在下面的框里按快捷键说一句话，文字会边识别边出现"][step - 1])
        self.back_btn.setVisible(step > 1)
        self.next_btn.setText("开始使用" if step == 3 else "下一步")
        if step == 3:
            self.trial.setFocus()

    def _load_key(self):
        self.key.setText(self.ctl.cfg["providers"][self.ctl.cfg["provider"]]["api_key"])

    def _store_key(self):
        p = self.ctl.cfg["providers"][self.ctl.cfg["provider"]]
        if p["api_key"] != self.key.text().strip():
            p["api_key"] = self.key.text().strip()
            self.ctl.changed()

    def _provider_changed(self, key):
        self._store_key()
        self.ctl.cfg["provider"] = key
        self.ctl.changed()
        self._load_key()
        _set_note(self.check_result, "")

    def _run_check(self):
        self._store_key()
        import copy
        trial = copy.deepcopy(self.ctl.cfg)
        if not config.active_provider(trial)[0]["api_key"]:
            _set_note(self.check_result, "请先填写 API Key")
            return
        self.check_btn.setEnabled(False)
        _set_note(self.check_result, "正在用一句测试语音实际识别一次…")
        threading.Thread(target=lambda: self._check_done.emit(engine.service_check(trial)), daemon=True).start()

    def _on_check(self, result):
        self.check_btn.setEnabled(True)
        _set_note(self.check_result, result)

    def _capture_hotkey(self):
        if self._capturing:
            return
        self._capturing = True
        self.ctl.engine.suspend_hotkey()
        self.ctl.learner.unregister_hotkey()
        self.ctl.system_snip.suspend()
        self.keycap.setText("请按键…（Esc 取消）")
        self.hotkey_btn.setEnabled(False)

        self._recorder.start()

    def _on_hotkey(self, name):
        if not self._capturing:
            return
        error = ""
        if name and name != "esc":
            try:
                self.ctl.cfg["hotkey"] = validate_candidate(self.ctl.cfg, name, "voice")
                self.ctl.changed()
            except ValueError as e:
                error = str(e)
        self.cancel_capture()
        if error:
            self.subtitle.setText(error)

    def cancel_capture(self):
        if not self._capturing:
            return
        self._recorder.cancel()
        self._capturing = False
        self.hotkey_btn.setEnabled(True)
        self.keycap.setText(hotkey_display(self.ctl.cfg["hotkey"]))
        self.ctl.engine.resume_hotkey()
        self.ctl.learner.register_hotkey()
        self.ctl.system_snip.resume()

    def closeEvent(self, e):
        self.cancel_capture()
        super().closeEvent(e)

    def _mode_changed(self, key):
        self.mode_hint.setText(MODE_HINTS[key])
        self.ctl.cfg["mode"] = key
        self.ctl.changed()

    def _back(self):
        if self.step == 1:
            return
        self._show(self.step - 1)

    def _next(self):
        if self.step == 1:
            self._store_key()
        if self.step == 3:
            self._finish()
            return
        self._show(self.step + 1)

    def _finish(self):
        if self.step == 1:
            self._store_key()
        self.cancel_capture()
        self.close()
        self.finished.emit()
