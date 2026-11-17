"""录音、词典、系统截图共用的快捷键解析和冲突校验。不安装钩子或发送按键。"""
import keyboard

MODIFIERS = ("ctrl", "alt", "windows", "shift")


def base_key(name):
    if name.startswith(("left ", "right ")) and name.split(" ", 1)[1] in MODIFIERS:
        return name.split(" ", 1)[1]
    return name


def key_ids(name):
    try:
        codes = keyboard.key_to_scan_codes(name)
    except (ValueError, KeyError) as e:
        raise ValueError(f"系统未能识别按键：{name}") from e
    if not codes:
        raise ValueError(f"系统未能识别按键：{name}")
    modifier = base_key(name) in MODIFIERS
    sides = (True,) if modifier and name.startswith("right ") else (False,) if modifier and name.startswith("left ") else (False, True)
    return {(code, side) for code in codes for side in sides}


def parse_hotkey(text, combined=False, sided=True):
    if not isinstance(text, str) or not text.strip():
        raise ValueError("请先设置快捷键")
    text = text.strip().lower()
    if text == "+":
        text = "plus"
    elif text.endswith("++"):
        text = text[:-1] + "plus"
    parts = []
    for raw in text.split("+"):
        part = raw.strip()
        if not part:
            raise ValueError("快捷键格式不完整")
        part = keyboard.normalize_name(part)
        if part == "+":
            part = "plus"  # 不与组合键分隔符混淆。
        if not sided:
            part = base_key(part)
        parts.append(part)
    if any(p == "esc" for p in parts):
        raise ValueError("Esc 用于取消录音，请换一个按键")
    mods = [p for p in parts if base_key(p) in MODIFIERS]
    keys = [p for p in parts if base_key(p) not in MODIFIERS]
    if combined and (not mods or len(keys) != 1):
        raise ValueError("请使用修饰键加一个普通键，例如 Ctrl + Alt + D")
    parts = sorted(mods, key=lambda p: MODIFIERS.index(base_key(p))) + keys
    groups = [key_ids(p) for p in parts]
    for i, group in enumerate(groups):
        if any(group & other for other in groups[i + 1:]):
            raise ValueError("同一个按键不能重复设置")
    generic = {base_key(p) for p in parts}
    if generic in ({"ctrl", "alt", "delete"}, {"windows", "l"}):
        raise ValueError("这个组合键由系统保留，请换一个")
    return "+".join(parts), groups


def overlaps(a, b):
    try:
        left = parse_hotkey(a)[1]
        right = parse_hotkey(b)[1]
    except ValueError:
        return False
    if len(left) != len(right):
        return False

    def match(index, used):
        if index == len(left):
            return True
        return any(not used & (1 << i) and left[index] & group and match(index + 1, used | (1 << i))
                   for i, group in enumerate(right))

    return match(0, 0)


def validate_candidate(cfg, text, role, index=None):
    name, _groups = parse_hotkey(text, combined=role != "voice", sided=role != "screenshot")
    if role != "voice" and overlaps(name, cfg.get("hotkey", "")):
        raise ValueError("和录音快捷键重复了，请换一个")
    if role != "dictionary" and overlaps(name, cfg.get("dictionary_hotkey", "")):
        raise ValueError("和词典快捷键重复了，请换一个")
    if cfg.get("screenshot_tool_enabled", False):
        for i, other in enumerate(cfg.get("screenshot_hotkeys", [])):
            if role == "screenshot" and i == index:
                continue
            if overlaps(name, other):
                raise ValueError(f"和截图快捷键 {i + 1} 重复了，请换一个")
    return name
