"""词典自动学习:从用户对语音结果的修改里找出"认错的词",以及读取输入框全文 / 选中文字。
规则与 macos/Sources/StreamingInput.swift 的 CorrectionLearner 一致,自检用例也相同。

- locate:在用户改完的全文里,用首尾各 4 个字锚定程序当初打进去的那一段。
- diff:公共前缀、公共后缀之外的中间段就是替换对;英文/数字扩到整词;只认一处替换,两边 1~12 个字;
  只加标点、只删字、整句重写都不算。
- Learner(界面层):回填后 15 秒内观察修改并询问/自动记住;选中文字 + 快捷键加入词典。
- 读取用 UI Automation(只读,不改输入框),每次在独立线程里新建 COM 对象;日志不记录读到的文字。
"""
from password_guard import is_password_element, focused_is_password
import logging
import threading
import time
import unicodedata

from PySide6.QtCore import QMimeData, QObject, QTimer, Signal
from PySide6.QtGui import QGuiApplication

import config
import screenshot
import streaming_input
from engine import get_foreground_app

log = logging.getLogger("learn")

ANCHOR = 4
MAX_WORD = 12


def locate(written, current):
    """在当前全文里找到程序打的那一段(用户可能改过),返回改后的那段;找不到返回 None。"""
    if not written or not current:
        return None
    if written in current:
        return written  # 没改
    head, tail = written[:ANCHOR], written[-ANCHOR:]
    start = current.find(head)
    end = current.find(tail, start + len(head)) if start >= 0 else -1
    if end < 0:
        # 改动落在首尾锚点里(短句常见):输入框里基本只有这一句时,整框就是改后的那段(Windows 补充,Mac 暂无)
        # 但两边得有足够多相同的首尾,避免把发送后剩下的占位提示文字当成改后的句子
        whole = current.strip()
        if abs(len(whole) - len(written)) > MAX_WORD:
            return None
        same = len(_common_prefix(written, whole)) + len(_common_prefix(written[::-1], whole[::-1]))
        return whole if same >= max(2, len(written) // 3) else None
    piece = current[start:end + len(tail)]
    if not (max(2, len(written) - 20) <= len(piece) <= len(written) + 20):
        return None
    return piece


def _common_prefix(a, b):
    n = 0
    while n < len(a) and n < len(b) and a[n] == b[n]:
        n += 1
    return a[:n]


def _alnum(ch):
    return ch.isascii() and ch.isalnum()



def diff(written, edited):
    """返回 (原词, 改成的词) 或 None。"""
    a, b = written, edited
    if a == b:
        return None
    p = 0
    while p < len(a) and p < len(b) and a[p] == b[p]:
        p += 1
    sa, sb = len(a), len(b)
    while sa > p and sb > p and a[sa - 1] == b[sb - 1]:
        sa -= 1
        sb -= 1
    frm, to = a[p:sa], b[p:sb]
    # 扩到词边界:英文/数字按整段字母数字,中文按字
    lp, rp = p, sa
    if not frm or _alnum(frm[0]):
        while lp > 0 and _alnum(a[lp - 1]):
            lp -= 1
    if not frm or _alnum(frm[-1]):
        while rp < len(a) and _alnum(a[rp]):
            rp += 1
    frm, to = a[lp:rp], b[lp:sb + (rp - sa)]
    frm, to = _clean(frm), _clean(to)
    if not to or not frm or to == frm:
        return None  # 纯新增/只删字/只改标点
    if len(to) > MAX_WORD or len(frm) > MAX_WORD:
        return None  # 整句重写
    if not any(ch.isalpha() for ch in to):
        return None
    return frm, to


def _clean(s):
    """去掉首尾的标点、空白和符号。"""
    i, j = 0, len(s)
    while i < j and (s[i].isspace() or unicodedata.category(s[i])[0] in "PS"):
        i += 1
    while j > i and (s[j - 1].isspace() or unicodedata.category(s[j - 1])[0] in "PS"):
        j -= 1
    return s[i:j]


# ---------- 读取输入框 ----------
UIA_VALUE_PATTERN, UIA_TEXT_PATTERN = 10002, 10014


def _focused():
    import comtypes
    import comtypes.client
    comtypes.CoInitialize()
    comtypes.client.GetModule("UIAutomationCore.dll")
    from comtypes.gen import UIAutomationClient as m
    uia = comtypes.client.CreateObject(m.CUIAutomation, interface=m.IUIAutomation)
    element = uia.GetFocusedElement()
    return m, None if is_password_element(element) else element


def _text_of(m, el):
    """优先 ValuePattern(普通输入框),再试 TextPattern(富文本、网页 contenteditable)。"""
    try:
        vp = el.GetCurrentPattern(UIA_VALUE_PATTERN)
        if vp:
            v = vp.QueryInterface(m.IUIAutomationValuePattern).CurrentValue
            if v:
                return v
    except Exception:
        pass
    try:
        tp = el.GetCurrentPattern(UIA_TEXT_PATTERN)
        if tp:
            return tp.QueryInterface(m.IUIAutomationTextPattern).DocumentRange.GetText(-1)
    except Exception:
        pass
    return None


def read_focused_text():
    """读当前焦点输入框的全文;读不到(如部分软件不支持)返回 None。"""
    try:
        m, el = _focused()
        return _text_of(m, el) if el is not None else None
    except Exception:
        log.warning("读取输入框失败", exc_info=True)
        return None


def read_selection():
    """读当前焦点控件里选中的文字(TextPattern);不支持返回 None,由调用方退回复制剪贴板。"""
    try:
        m, el = _focused()
        if el is None:
            return None
        tp = el.GetCurrentPattern(UIA_TEXT_PATTERN)
        if not tp:
            return None
        ranges = tp.QueryInterface(m.IUIAutomationTextPattern).GetSelection()
        text = "".join(ranges.GetElement(i).GetText(-1) for i in range(ranges.Length))
        return text or None
    except Exception:
        log.warning("读取选中文字失败", exc_info=True)
        return None


def run_async(fn, done):
    """在独立线程里执行 fn(COM 对象不跨线程),结果交给 done(result)(由调用方转回界面线程)。"""
    threading.Thread(target=lambda: done(fn()), daemon=True).start()


# ---------- 界面层:学习流程与词典快捷键(与 Mac 的 openLearnWindow / offerCorrection / addSelectionToDictionary 一致) ----------
LEARN_SECONDS = 15   # 打完一句后观察多久
ASK_SECONDS = 6      # 询问胶囊停留多久(Mac 是 4 秒,用户嫌来不及按,改 6 秒)
IGNORE_LIMIT = 2     # 同一处纠错被忽略几次后不再问
READ_DELAY = 300     # 停手多少毫秒读一次输入框(改完马上发送也来得及读到)
SETTLE = 1.0         # 停手多少秒算改完


def _looks_like_pinyin(frm, to):
    """中文被改成一串小写字母:多半是输入法还没上屏的拼音,不是真的改词。"""
    return any("一" <= ch <= "鿿" for ch in frm) and to.isascii() and to.isalpha() and to.islower()


class Learner(QObject):
    """打完一句话后 15 秒内,用户真的改了字就读回输入框比对,找出"认错的词"按设置询问/自动记住;
    另管"选中文字 + 快捷键加入词典"。方法都在界面线程执行,后台线程的结果经信号转回来。
    和 Mac 的差别:Mac 停手 1 秒才读一次;这里每次停手 0.3 秒就读、记下最新的差异,
    停手满 1 秒或输入框里那句话不见了(改完马上按回车发出去了)时再提出来。"""
    _read_done = Signal(object, float)  # 读回的输入框全文, 开始读的时间
    _selection_done = Signal(object)  # UIA 读到的选中文字,None 表示要退回复制
    _copy_done = Signal(bool)         # 模拟 Ctrl+C 后剪贴板有没有变
    _hotkey_fired = Signal()
    _confirm_key = Signal()           # 询问期间按了 Ctrl+Enter(钩子线程发来)

    def __init__(self, app):
        super().__init__()
        self.app = app
        self._window = None    # {"dest","written","until","last_input","found","found_at"}
        self._pending = None   # (原词, 改成的词)
        self._deadline = 0.0
        self._interceptor = None
        self._hotkey = None
        self._hook = None
        self._saved_clip = None
        self._poll = QTimer(self, interval=250, timeout=self._poll_window)
        self._read_timer = QTimer(self, singleShot=True, interval=READ_DELAY, timeout=self._read_now)
        self._ask_timer = QTimer(self, interval=33, timeout=self._ask_tick)
        self._read_done.connect(self._on_read)
        self._selection_done.connect(self._on_selection)
        self._copy_done.connect(self._on_copied)
        self._hotkey_fired.connect(self._add_selection)
        self._confirm_key.connect(self.confirm)
        app.overlay.clicked.connect(self.confirm)
        app.engine.wrote.connect(self.open_window)
        app.engine.user_input.connect(self._on_user_input)

    # ----- 从修改中学习 -----
    def open_window(self, info):
        self._close_window()
        if self.app.cfg.get("dictionary_learn", "ask") == "off" or len(info["text"]) < 2:
            return
        self._window = {"dest": streaming_input.Destination(info["hwnd"], info["focus"]), "written": info["text"],
                        "until": time.monotonic() + LEARN_SECONDS, "last_input": 0.0, "found": None, "found_at": 0.0}
        self._poll.start()

    def _on_user_input(self, _kind, pt):
        w = self._window
        if w:
            now = time.monotonic()
            w["last_input"] = now
            w["until"] = max(w["until"], now + SETTLE + 1)  # 还在改就多等一会儿
            self._read_timer.start()
        if self._pending:
            if pt is not None and self._on_overlay(pt):
                return  # 点的就是询问胶囊,交给 clicked 处理
            self.dismiss(ignored=False)

    def _on_overlay(self, pt):
        from ui import to_logical
        o = self.app.overlay
        return o.isVisible() and o.frameGeometry().contains(to_logical(*pt).toPoint())

    def _read_now(self):
        w = self._window
        if w is None or not w["dest"].is_current():
            return
        t = time.monotonic()
        run_async(read_focused_text, lambda text: self._read_done.emit(text, t))

    def _on_read(self, current, t):
        w = self._window
        if w is None:
            return
        if current is None:
            log.info("纠错学习: 读不到输入框内容")
            return
        edited = locate(w["written"], current)
        if edited is None:
            # 那句话不见了:多半是改完直接发送了,用发送前最后读到的差异
            log.info("纠错学习: 输入框里找不到原句(%d 字)%s", len(current), ",用发送前的修改" if w["found"] else "")
            if w["found"]:
                self._offer_found()
            return
        found = diff(w["written"], edited)
        if found and _looks_like_pinyin(*found):
            return  # 输入法还在拼,等上屏
        w["found"], w["found_at"] = found, t
        if found:
            log.info("纠错学习: 发现修改 %d→%d 字", len(found[0]), len(found[1]))

    def _poll_window(self):
        w = self._window
        if w is None or self.app.state != "idle":
            self._close_window()
            return
        now = time.monotonic()
        settled = w["last_input"] and now - w["last_input"] >= SETTLE
        if w["found"] and settled and w["found_at"] >= w["last_input"]:
            self._offer_found()
        elif now > w["until"]:
            self._close_window()

    def _offer_found(self):
        found = self._window["found"]
        self._close_window()
        self.offer(*found)

    def _close_window(self):
        self._window = None
        self._poll.stop()
        self._read_timer.stop()

    def offer(self, frm, to):
        cfg = self.app.cfg
        if config.has_word(cfg, to):
            return
        key = f"{frm}→{to}"
        ignored = cfg["dictionary_ignored"]
        if ignored.get(key, 0) >= IGNORE_LIMIT:
            return
        if cfg.get("dictionary_learn") == "auto":
            seen = ignored.get("seen:" + key, 0) + 1
            ignored["seen:" + key] = seen
            if seen >= 2:
                self.learn(to)
            else:  # 第一次只记一笔,不打扰
                log.info("纠错学习: 首次见到 %d→%d 字,先记一笔", len(frm), len(to))
                self.app.save_config()
            return
        self._pending = (frm, to)
        self._deadline = time.monotonic() + ASK_SECONDS
        if self._interceptor is None:
            self._interceptor = streaming_input.KeyInterceptor(self._confirm_key.emit)
        self.app.overlay.set_anchor({"mode": "cursor", "pointer": screenshot.cursor_pos()})
        self.app.overlay.set_state("learn_ask", to)
        self._ask_timer.start()

    def _ask_tick(self):
        if not self._pending:
            self._ask_timer.stop()
            return
        left = self._deadline - time.monotonic()
        if left <= 0:
            self.dismiss(ignored=True)
        else:
            self.app.overlay.set_progress(left / ASK_SECONDS)

    def _end_ask(self):
        self._pending = None
        self._ask_timer.stop()
        if self._interceptor:
            self._interceptor.stop()
            self._interceptor = None

    def confirm(self):
        if not self._pending:
            return
        to = self._pending[1]
        self._end_ask()
        self.learn(to)

    def dismiss(self, ignored):
        if not self._pending:
            return
        key = "→".join(self._pending)
        self._end_ask()
        self.app.overlay.set_state("idle")
        if ignored:
            ig = self.app.cfg["dictionary_ignored"]
            ig[key] = ig.get(key, 0) + 1
            self.app.save_config()

    def learn(self, word):
        app_name = get_foreground_app()[0]
        added = config.add_words(self.app.cfg, [word], app=app_name, source="correction")
        self.app.save_config(dictionary=True)
        if not added:
            self.app.overlay.set_state("idle")
            return
        self.app.overlay.set_state("learned", "\n".join(added))
        log.info("纠错学习: 记住 1 个词(来源 %s)", app_name)

    # ----- 选中文字加入词典 -----
    def register_hotkey(self):
        hk = self.app.cfg.get("dictionary_hotkey", "")
        if self._hotkey == hk:
            return
        self.unregister_hotkey()
        if not hk:
            return
        try:
            self._hook = streaming_input.HotkeyHook(hk, self._on_hotkey_thread)
            self._hotkey = hk
        except Exception:
            log.warning("词典快捷键注册失败: %s", hk, exc_info=True)

    def _on_hotkey_thread(self):
        # 在 HotkeyHook 另开的线程里执行(修饰键还按着)。触发键被吞掉后,系统只看到"单按了 Alt(或 Alt+Shift)",松开时会激活菜单栏抢走焦点、
        # 或切换输入法;趁修饰键还按着插一个无效按键打断它(说话热键用的同一招)
        from engine import cancel_menu_activation
        cancel_menu_activation()
        self._hotkey_fired.emit()

    def unregister_hotkey(self):
        if self._hotkey:
            self._hook.stop()
            self._hook = None
            self._hotkey = None

    def _add_selection(self):
        if self.app.state != "idle":
            return
        run_async(read_selection, self._selection_done.emit)

    def _on_selection(self, text):
        if focused_is_password():
            return
        if text and text.strip():
            self._add_text(text)
            return
        # UIA 读不到选区(很多软件不支持):模拟一次 Ctrl+C,读完再把剪贴板恢复原样
        self._saved_clip = _clone_mime(QGuiApplication.clipboard().mimeData())
        engine = self.app.engine

        def copy():
            streaming_input.wait_modifiers_released(1.5)
            if focused_is_password():
                return False
            engine.ignore_keys(0.8)
            seq = streaming_input.user32.GetClipboardSequenceNumber()
            streaming_input.send_ctrl_c()
            end = time.monotonic() + 0.5
            while time.monotonic() < end:
                if streaming_input.user32.GetClipboardSequenceNumber() != seq:
                    time.sleep(0.05)  # 让源程序把各种格式写完
                    return True
                time.sleep(0.02)
            return False
        run_async(copy, self._copy_done.emit)

    def _on_copied(self, changed):
        clip = QGuiApplication.clipboard()
        text = clip.text() if changed else ""
        if changed and self._saved_clip is not None:
            clip.setMimeData(self._saved_clip)
        self._saved_clip = None
        self._add_text(text)

    def _add_text(self, text):
        text = (text or "").strip()
        overlay = self.app.overlay
        overlay.set_anchor({"mode": "cursor", "pointer": screenshot.cursor_pos()})
        if not text or len(text) > 200:
            overlay.set_state("error", "先选中要加的词")
            return
        app_name = get_foreground_app()[0]
        words = config.split_words(text)
        added = config.add_words(self.app.cfg, words, app=app_name, source="hotkey")
        self.app.save_config(dictionary=True)
        if not added:
            overlay.set_state("error", "词典里已经有了" if words else "没有可加的词")
            return
        overlay.set_state("learned", "\n".join(added))
        log.info("词典: 快捷键加入 %d 个(来源 %s)", len(added), app_name)

    def stop(self):
        self._end_ask()
        self.unregister_hotkey()


def _clone_mime(src):
    """剪贴板内容的深拷贝(原对象归剪贴板所有,内容一换就失效)。"""
    if src is None:
        return None
    dst = QMimeData()
    for fmt in src.formats():
        dst.setData(fmt, src.data(fmt))
    return dst
