"""只读取UIA密码属性，不读取输入框的文字。UIA对象按线程创建，不能跨线程共享。"""
import threading

IS_PASSWORD = 30019
_local = threading.local()


def is_password_element(element):
    if element is None:
        return False
    try:
        value = element.GetCurrentPropertyValue(IS_PASSWORD)
        return isinstance(value, (bool, int)) and bool(value)
    except Exception:
        return False  # 控件未提供属性时无法判断，不宣称覆盖全部软件。


def has_password_ancestor(element, walker, limit=4):
    for _ in range(limit + 1):
        if element is None:
            break
        if is_password_element(element):
            return True
        try:
            element = walker.GetParentElement(element)
        except Exception:
            break
    return False


def _automation():
    if not hasattr(_local, "uia"):
        import comtypes
        import comtypes.client
        comtypes.CoInitialize()
        comtypes.client.GetModule("UIAutomationCore.dll")
        from comtypes.gen import UIAutomationClient as mod
        _local.uia = comtypes.client.CreateObject(mod.CUIAutomation, interface=mod.IUIAutomation)
    return _local.uia


def focused_is_password():
    try:
        uia = _automation()
        return has_password_ancestor(uia.GetFocusedElement(), uia.ControlViewWalker)
    except Exception:
        return False
