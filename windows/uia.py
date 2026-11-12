"""用 Windows UI Automation 判断鼠标下的控件是不是可编辑的文本输入框。

只在调用它的线程里使用(COM 对象不能跨线程),由 mouse_trigger 的工作线程独占。
"""
import ctypes
import logging
from ctypes import wintypes

import comtypes
import comtypes.client
from password_guard import is_password_element, has_password_ancestor

log = logging.getLogger("uia")

# 控件类型 id
CT_EDIT = 50004
CT_DOCUMENT = 50030
CT_COMBOBOX = 50003
CONTROL_TYPE_NAMES = {
    50000: "Button", 50003: "ComboBox", 50004: "Edit", 50020: "Text", 50025: "Custom",
    50026: "Group", 50030: "Document", 50032: "Window", 50033: "Pane", 50008: "List",
    50007: "ListItem", 50005: "Hyperlink", 50006: "Image", 50023: "Tree", 50024: "TreeItem",
}
# 属性 id
P_IS_VALUE_AVAILABLE = 30043
P_VALUE_READONLY = 30046
P_IS_TEXT_AVAILABLE = 30040
P_IS_KEYBOARD_FOCUSABLE = 30009
P_HAS_KEYBOARD_FOCUS = 30008
P_FRAMEWORK_ID = 30024

MAX_ANCESTORS = 4  # 鼠标下可能是输入框内部的文字节点,向上找几层
# 终端的整块文字区在 UIA 里是只读 Text,但实际可以打字:Windows 终端 / 老式控制台窗口
TERMINAL_CLASSES = {"TermControl", "ConsoleWindowClass"}


class Inspector:
    def __init__(self):
        comtypes.CoInitialize()
        comtypes.client.GetModule("UIAutomationCore.dll")
        from comtypes.gen import UIAutomationClient as uia_mod
        self._mod = uia_mod
        self._uia = comtypes.client.CreateObject(
            uia_mod.CUIAutomation, interface=uia_mod.IUIAutomation)
        self._walker = self._uia.ControlViewWalker

    def _prop(self, el, pid):
        try:
            return el.GetCurrentPropertyValue(pid)
        except Exception:
            return None

    def _describe(self, el):
        ct = self._prop(el, 30003)  # ControlType
        return {
            "type": CONTROL_TYPE_NAMES.get(ct, str(ct)),
            "class": (el.CurrentClassName or "")[:40],
            "framework": self._prop(el, P_FRAMEWORK_ID) or "",
            "focusable": bool(self._prop(el, P_IS_KEYBOARD_FOCUSABLE)),
            "value": bool(self._prop(el, P_IS_VALUE_AVAILABLE)),
            "readonly": self._prop(el, P_VALUE_READONLY),
            "text": bool(self._prop(el, P_IS_TEXT_AVAILABLE)),
            "_ct": ct,
            "password": is_password_element(el),
        }

    @staticmethod
    def _editable(d):
        """Edit 控件:不是只读就算;Document:必须可聚焦且值可写(排除网页正文等只读文档);终端整块文字区都算。"""
        if d.get("password"):
            return False
        if d["class"] in TERMINAL_CLASSES:
            return True
        if d["_ct"] == CT_EDIT:
            return not (d["value"] and d["readonly"] is True)
        if d["_ct"] == CT_DOCUMENT:
            return d["focusable"] and d["value"] and d["readonly"] is False
        return False

    def is_password_at(self, x, y):
        # 此否决必须先于父元素和文字光标兜底，避免密码框被重新判为可编辑。
        for lookup in (lambda: self._uia.ElementFromPoint(wintypes.POINT(x, y)), self._uia.GetFocusedElement):
            try:
                if has_password_ancestor(lookup(), self._walker):
                    return True
            except Exception:
                continue
        return False

    def inspect_point(self, x, y):
        """返回 (是否输入框, 诊断信息字符串)。"""
        try:
            el = self._uia.ElementFromPoint(wintypes.POINT(x, y))
        except Exception as e:
            return False, f"ElementFromPoint 失败: {e}"
        chain = []
        for _ in range(MAX_ANCESTORS + 1):
            if el is None:
                break
            d = self._describe(el)
            chain.append(d)
            if d["password"]:
                return False, "受保护输入框"
            if self._editable(d):
                return True, self._fmt(chain)
            try:
                el = self._walker.GetParentElement(el)
            except Exception:
                break
        return False, self._fmt(chain)

    def inspect_focus(self, x, y):
        """当前焦点控件可编辑,且 (x, y) 在它的范围内。返回 (是否命中, 诊断信息)。"""
        el = self._uia.GetFocusedElement()
        if el is None:
            return False, "无焦点"
        d = self._describe(el)
        if d["password"]:
            return False, "受保护输入框"
        b = el.CurrentBoundingRectangle
        inside = b.left <= x < b.right and b.top <= y < b.bottom
        editable = self._editable(d) or (
            # Chromium 的 contenteditable 有时是可聚焦、支持文本模式的 Group/Custom
            d["focusable"] and d["text"] and d["readonly"] is not True and d["_ct"] not in (CT_DOCUMENT,))
        return editable and inside, f"{self._fmt([d])}{'' if inside else '(鼠标不在范围内)'}"

    @staticmethod
    def _fmt(chain):
        parts = []
        for d in chain:
            flags = "".join(c for c, on in (("F", d["focusable"]), ("V", d["value"]), ("T", d["text"])) if on)
            ro = "" if d["readonly"] is None else ("/只读" if d["readonly"] else "/可写")
            parts.append(f"{d['type']}[{d['class']}|{d['framework']}|{flags}{ro}]")
        return " ← ".join(parts)
