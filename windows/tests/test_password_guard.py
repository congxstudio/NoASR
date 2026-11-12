"""密码框保护的逻辑测试，不加载COM、录音、键盘钩子或SendInput。"""
import ast
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("test_guard", ROOT / "password_guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def method(filename, classname, name, namespace):
    tree = ast.parse((ROOT / filename).read_text(encoding="utf-8"))
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == classname)
    node = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == name)
    node.decorator_list = []
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(ROOT / filename), "exec"), namespace)
    return namespace[name]


class PasswordGuardTests(unittest.TestCase):
    def test_property_does_not_read_password_text(self):
        el = Mock()
        el.GetCurrentPropertyValue.return_value = True
        self.assertTrue(guard.is_password_element(el))
        el.GetCurrentPropertyValue.assert_called_once_with(30019)
        el.GetCurrentPattern.assert_not_called()

    def test_normal_unknown_and_failed_property(self):
        for value in (False, 0, None, object()):
            self.assertFalse(guard.is_password_element(SimpleNamespace(GetCurrentPropertyValue=lambda _id: value)))
        self.assertFalse(guard.is_password_element(None))
        el = Mock(); el.GetCurrentPropertyValue.side_effect = RuntimeError("unavailable")
        self.assertFalse(guard.is_password_element(el))

    def test_password_parent_blocks_inner_text_child(self):
        parent = SimpleNamespace(GetCurrentPropertyValue=lambda _id: True)
        child = SimpleNamespace(GetCurrentPropertyValue=lambda _id: False)
        walker = SimpleNamespace(GetParentElement=lambda el: parent if el is child else None)
        self.assertTrue(guard.has_password_ancestor(child, walker))

    def test_mouse_password_denial_precedes_caret_fallback(self):
        caret = Mock(side_effect=AssertionError("不应执行光标兜底"))
        judge = method("mouse_trigger.py", "MouseTrigger", "_judge", {"_caret_window": caret})
        inspector = Mock(); inspector.is_password_at.return_value = True
        hit, _ = judge(inspector, 1, 2)
        self.assertFalse(hit)
        inspector.inspect_point.assert_not_called()
        inspector.inspect_focus.assert_not_called()
        caret.assert_not_called()

    def test_password_is_not_editable_even_for_terminal(self):
        editable = method("uia.py", "Inspector", "_editable", {"TERMINAL_CLASSES": {"TermControl"}})
        self.assertFalse(editable({"password": True, "class": "TermControl"}))

    def test_keyboard_begin_does_not_open_recording_or_device(self):
        begin = method("engine.py", "Engine", "_begin", {"CUE_DELAY": 0, "focused_is_password": lambda: True})
        engine = SimpleNamespace(state=Mock())
        begin(engine)
        engine.state.emit.assert_called_once_with("error", "受保护输入框中不启动语音")

    def test_destination_capture_and_writes_are_rejected(self):
        ns = {"focused_is_password": lambda: True}
        capture = method("streaming_input.py", "Destination", "capture", ns)
        current = method("streaming_input.py", "Destination", "is_current", ns)
        self.assertIsNone(capture(object))
        self.assertFalse(current(object()))

    def test_dictionary_selection_does_not_fall_back_to_copy_in_password(self):
        handler = method("learn.py", "Learner", "_on_selection", {"focused_is_password": lambda: True})
        learner = Mock()
        handler(learner, None)
        learner._add_text.assert_not_called()



if __name__ == "__main__":
    unittest.main()
