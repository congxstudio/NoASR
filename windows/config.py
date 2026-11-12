"""配置与历史记录的读写。文件保存在程序目录下,已被 .gitignore 忽略。"""
import json
import os
import re
import shutil
import sys
import threading
import time

_history_lock = threading.Lock()

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
# 兼容迁移前的本地数据,避免已有 Windows 用户重新填写 Key。
_LEGACY_DIR = os.path.dirname(SOURCE_DIR)
BASE_DIR = (_LEGACY_DIR if os.path.exists(os.path.join(_LEGACY_DIR, "config.json"))
            else SOURCE_DIR)
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
HISTORY_PATH = os.path.join(BASE_DIR, "history.json")
LOG_PATH = os.path.join(BASE_DIR, "app.log")
ICON_PATH = os.path.join(SOURCE_DIR, "assets", "onemore.ico")
RECORDINGS_DIR = os.path.join(BASE_DIR, "recordings")
LOG_MAX_BYTES = 512 * 1024  # 日志滚动:当前文件 + 1 个备份,合计不超过 1MB

APP_NAME = "OneMore"
APP_VERSION = "1.0.0"  # 显示在设置窗口左下角;分发给别人时改这里,便于区分版本

# 识别服务商。kind: openai = OpenAI 兼容 chat/completions;gemini = Google 原生接口。
# route: direct 只直连(国内节点,不走 VPN 代理) / proxy_first 系统代理优先、连不上改直连 / proxy 只走系统代理。
# screenshot_models: 支持"音频 + 截图"同一请求的模型前缀,其他模型只发语音。
PROVIDERS = {
    "bailian_cn": {
        "name": "百炼·北京",
        "kind": "openai",
        "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "model": "qwen3.5-omni-flash",
        "audio_prefix": "data:;base64,",
        "extra_body": {"modalities": ["text"], "enable_thinking": False},
        "env_key": "DASHSCOPE_CN_API_KEY",
        "route": "direct",
        "models": {
            "qwen3-omni-flash": "Qwen3 Omni Flash",
            "qwen3.5-omni-flash": "Qwen3.5 Omni Flash(最快)",
            "qwen3.8-omni-flash": "Qwen3.8 Omni Flash(最便宜)",
        },
        "screenshot_models": ("qwen3.5-omni", "qwen3.8-omni"),
    },
    "bailian": {
        "name": "百炼·新加坡",
        "kind": "openai",
        "base_url": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "model": "qwen3.5-omni-flash",
        "audio_prefix": "data:;base64,",  # 百炼不认带 mime 的写法也能用,保持已验证的形式
        # 转写不需要思考:统一关闭思考模式(3.8 默认开启,不关一句话要 5 秒)
        "extra_body": {"modalities": ["text"], "enable_thinking": False},
        "env_key": "DASHSCOPE_API_KEY",
        "route": "proxy_first",  # 海外节点走 VPN 更快;VPN 没开时退回直连
        "models": {
            "qwen3-omni-flash": "Qwen3 Omni Flash",
            "qwen3.5-omni-flash": "Qwen3.5 Omni Flash(最快)",
            "qwen3.8-omni-flash": "Qwen3.8 Omni Flash(最便宜)",
        },
        "screenshot_models": ("qwen3.5-omni", "qwen3.8-omni"),
    },
    "mimo": {
        "name": "小米 MiMo",
        "kind": "openai",
        "base_url": "https://api.xiaomimimo.com/v1",
        "model": "mimo-v2.6-flash",
        "audio_prefix": "data:{mime};base64,",
        # 默认开启思考模式,结果会落在 reasoning_content 里,转写不需要思考
        "extra_body": {"thinking": {"type": "disabled"}},
        "env_key": "MIMO_API_KEY",
        "route": "direct",
        "models": {"mimo-v2.6-flash": "MiMo V2.6 Flash"},
        "screenshot_models": ("mimo-v2.6",),
    },
    "gemini": {
        "name": "Gemini",
        "kind": "gemini",
        "base_url": "https://generativelanguage.googleapis.com/v1beta",
        "model": "gemini-3.8-flash",
        "env_key": "GEMINI_API_KEY",
        "route": "proxy",  # 国内需要 VPN
        "models": {
            "gemini-3.8-flash": "Gemini 3.8 Flash",
            "gemini-3.5-flash-lite": "Gemini 3.5 Flash Lite",
            "gemini-3.6-flash": "Gemini 3.6 Flash",
            "gemini-4-argon": "Gemini 4 Argon",
        },
        "screenshot_models": ("gemini-",),
    },
    "volcano": {
        "name": "火山方舟",
        "kind": "openai",
        "base_url": "https://ark.cn-beijing.volces.com/api/v3",
        "model": "doubao-seed-2-1-lite-260915",
        "audio_prefix": "",  # 火山要纯 base64,不带 data: 前缀
        "extra_body": {"thinking": {"type": "disabled"}, "max_tokens": 8192},
        "env_key": "ARK_API_KEY",
        "route": "direct",
        "models": {
            "doubao-seed-2-1-lite-260915": "Seed 2.1 Lite",
            "doubao-seed-2-0-lite-260428": "Seed 2.0 Lite",
            "doubao-seed-2-0-mini-260428": "Seed 2.0 Mini",
        },
        "screenshot_models": ("doubao-seed-",),
    },
}


def request_extra(meta, model):
    """某个模型调用时要附加的请求参数 = 服务商通用参数 + 该模型专属参数。"""
    return {**meta.get("extra_body", {}), **meta.get("model_extra", {}).get(model, {})}


def model_title(provider, model):
    return PROVIDERS.get(provider, {}).get("models", {}).get(model, model)


def supports_screenshot(provider, model):
    return model.startswith(PROVIDERS[provider].get("screenshot_models", ()))


DEFAULT_PROMPT = '你是用户的表达助手，录音是用户的原始说话内容，请理解说话内容后，帮助他进行流畅表达，请直接输出优化后的内容结果，其他信息一概不要输出，比如你的思考过程、你对结果的补充描述等等。\n\n背景（这段不要输出）：录音中可能包含口头禅、语气词重复、停顿与思考过程，语句也可能断断续续。请在不改变原意的前提下，将内容整理为通顺、连贯、不废话、符合表达习惯的语句，同时保留必要的语义完整性与自然节奏，避免过度删减导致信息丢失。根据内容自然分段，不同话题或要点之间空一行；短内容不必强行分段。"呃、嗯、啊、那个、这个、然后"这类语气词和口头禅一律删掉，重复的词只保留一次\n\n硬性约束（违反比不整理更糟）：\n1. 不得改变肯定/否定。原话说"是、要、能、有"，就不能写成"不是、不要、不能、没有"；反之同理。\n2. 不得改变数量、程度、范围、时间和主语。\n3. 不得替用户推断结论；拿不准的地方原样保留，宁可口语化。\n4. 只允许：删语气词、去重复、补标点、顺句子。不允许换词、不允许改写立场。'

DEFAULTS = {
    "provider": "bailian",
    "providers": {k: {"api_key": "", "base_url": v["base_url"], "model": v["model"]}
                  for k, v in PROVIDERS.items()},
    "volcano_fast": False,  # 火山 Fast 低延迟档(需在火山控制台开通)
    "hotkey": "left ctrl",
    "mode": "both",  # hold 按住说话 / toggle 单击切换 / both 短按切换、长按说话
    "strip_trailing_punct": True,
    "app_context": True,  # 把当前前台程序名和窗口标题附加到提示词
    "window_screenshot": False,  # 录音时附带当前窗口截图
    "screenshot_consent": False,  # 用户已看过截图说明并同意
    "screenshot_tool_enabled": True,  # 附带工具:系统截图快捷键转发
    "screenshot_hotkeys": ["alt+shift+a", "windows+shift+a"],
    "mouse_longpress": True,  # 输入框内长按左键录音
    "device": "",  # 空字符串表示系统默认麦克风
    "prompt": DEFAULT_PROMPT,
    "autostart": True,
    "sound": True,
    "sound_volume": 0.85,
    "sound_style": "bell",
    "overlay_position": "window",
    "appearance": "system",  # 外观:system 跟随系统 / light 浅色 / dark 深色
    # 个人词典:[{"word", "source": manual/hotkey/correction, "app": 添加时所在程序, "added", "last_hit"}]
    "dictionary": [],
    "dictionary_hotkey": "ctrl+alt+d",  # 选中文字加入词典
    "dictionary_learn": "ask",  # 从修改中学习:ask 每次询问 / auto 第 2 次自动记住 / off 关闭
    "dictionary_ignored": {},  # "错→对": 被忽略次数(2 次后不再问);"seen:错→对": 自动模式下见过的次数
    "history_enabled": True,
    "history_limit": 100,  # 0 表示永久保留
    # 本机转写接口(asr_bridge.py,供本机其他应用使用):token 为空则不启动
    "asr_bridge_port": 8095,
    "asr_bridge_token": "",
}
HISTORY_LIMITS = (1, 3, 10, 50, 100, 0)
SOUND_STYLES = {"bell": "铃声", "marimba": "木琴", "bubble": "气泡", "chime": "双音", "coin": "金币"}
OVERLAY_POSITIONS = {"window": "跟随窗口", "bottom": "固定底部", "cursor": "跟随光标"}
# 旧版逐字转写提示词:迁移时自动换成新的默认,用户改过的保持不变
LEGACY_PROMPT = "请把这段语音逐字转写为文字,只输出转写结果,不要解释。保留原语言,自动补全标点。"


def load_config():
    cfg = json.loads(json.dumps(DEFAULTS))  # 深拷贝
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            saved = json.load(f)
    except (OSError, ValueError):
        saved = {}
    # 兼容旧版扁平配置(只有百炼)
    legacy = {k: saved.pop(k) for k in ("api_key", "base_url", "model") if k in saved}
    if legacy:
        saved.setdefault("providers", {}).setdefault("bailian", {}).update(legacy)
    for name, p in saved.pop("providers", {}).items():
        if name in cfg["providers"]:
            cfg["providers"][name].update(p)
    cfg.update(saved)
    cfg.pop("keep_training_audio", None)  # 已移除高清训练素材功能，不沿用旧开关
    if not isinstance(cfg.get("screenshot_hotkeys"), list):
        cfg["screenshot_hotkeys"] = list(DEFAULTS["screenshot_hotkeys"])
    cfg["screenshot_hotkeys"] = list(dict.fromkeys(
        k.strip().lower() for k in cfg["screenshot_hotkeys"] if isinstance(k, str) and k.strip()))
    if cfg["provider"] not in PROVIDERS:
        cfg["provider"] = "bailian"
    if cfg.get("history_limit") not in HISTORY_LIMITS:
        cfg["history_limit"] = 100
    if cfg.get("sound_style") not in SOUND_STYLES:
        cfg["sound_style"] = "bell"
    if not isinstance(cfg.get("dictionary"), list):
        cfg["dictionary"] = []
    cfg["dictionary"] = [e for e in cfg["dictionary"] if isinstance(e, dict) and str(e.get("word", "")).strip()]
    if cfg.get("dictionary_learn") not in ("ask", "auto", "off"):
        cfg["dictionary_learn"] = "ask"
    if not isinstance(cfg.get("dictionary_ignored"), dict):
        cfg["dictionary_ignored"] = {}
    if cfg.get("appearance") not in ("system", "light", "dark"):
        cfg["appearance"] = "system"
    if cfg.get("overlay_position") not in OVERLAY_POSITIONS:
        cfg["overlay_position"] = "window"
    if cfg.get("prompt", "").strip() in ("", LEGACY_PROMPT):
        cfg["prompt"] = DEFAULT_PROMPT
    cfg["sound_volume"] = min(1.0, max(0.0, float(cfg.get("sound_volume", 0.85))))
    for name, p in cfg["providers"].items():
        p["api_key"] = p.get("api_key", "").strip()
        if p.get("model") not in PROVIDERS[name]["models"]:
            p["model"] = PROVIDERS[name]["model"]  # 模型只能从列表里选,旧配置里手填的名字换成默认
        if not p["api_key"]:
            p["api_key"] = os.getenv(PROVIDERS[name]["env_key"], "")
    return cfg


# ---------- 个人词典 ----------
WORD_MAX_LEN = 40
_WORD_SPLIT = re.compile(r"[,，、;；\n\r\t]+| {2,}|(?<=[^\x00-\x7f]) +| +(?=[^\x00-\x7f])")


def split_words(text):
    """把输入框里的一段文字拆成多个词条:逗号、顿号、分号、换行都算分隔;
    空格只在中文旁边或连续多个时才分隔,这样"Claude Code"这种英文短语能保留成一个词条。"""
    out = []
    for w in _WORD_SPLIT.split(text or ""):
        w = w.strip().strip("\"'“”‘’「」『』")
        if w and len(w) <= WORD_MAX_LEN:
            out.append(w)
    return out


def word_key(word):
    """去重用:忽略大小写和首尾空白,"claude" 和 "Claude" 算同一个。"""
    return word.strip().casefold()


SOURCES = {"manual": "手动添加", "hotkey": "快捷键加入", "correction": "从修改中学到"}


def add_words(cfg, words, app="", source="manual"):
    """把词条加进词典(自动去重,保留最先加入的写法),返回真正新加的词条。"""
    existing = {word_key(e["word"]) for e in cfg["dictionary"]}
    added = []
    for w in words:
        k = word_key(w)
        if k in existing:
            continue
        existing.add(k)
        cfg["dictionary"].append({"word": w, "source": source, "app": app,
                                  "added": time.strftime("%Y-%m-%d %H:%M:%S")})
        added.append(w)
    return added


def has_word(cfg, word):
    k = word_key(word)
    return any(word_key(e["word"]) == k for e in cfg["dictionary"])


def mark_hits(cfg, text):
    """识别结果里出现的词条记一次命中时间(以后"按需加载"的依据),返回有没有变化。"""
    low = text.casefold()
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    hit = False
    for e in cfg["dictionary"]:
        if e["word"].casefold() in low:
            e["last_hit"] = now
            hit = True
    return hit


def remove_word(cfg, word):
    k = word_key(word)
    cfg["dictionary"] = [e for e in cfg["dictionary"] if word_key(e["word"]) != k]


def active_provider(cfg):
    """返回当前服务商的 (配置, 元信息)。"""
    name = cfg["provider"]
    return cfg["providers"][name], PROVIDERS[name]


def save_config(cfg):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_PATH)  # 先写临时文件再替换,写到一半断电也不会损坏配置


def load_history():
    try:
        with open(HISTORY_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def _write_history(items):
    tmp = HISTORY_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)
    os.replace(tmp, HISTORY_PATH)


def new_record_id():
    return time.strftime("%Y%m%d-%H%M%S") + f"-{int(time.time() * 1000) % 1000:03d}"


def save_recording(rid, payload, ext):
    """保存上传用的音频或截图,返回文件名。"""
    os.makedirs(RECORDINGS_DIR, exist_ok=True)
    fname = f"{rid}.{ext}"
    with open(os.path.join(RECORDINGS_DIR, fname), "wb") as f:
        f.write(payload)
    return fname


def recording_path(entry):
    return os.path.join(RECORDINGS_DIR, entry["audio"]) if entry.get("audio") else None


def screenshot_path(entry):
    return os.path.join(RECORDINGS_DIR, entry["screenshot"]) if entry.get("screenshot") else None


def new_history_entry(rid, **fields):
    """一条历史记录。stats:识别统计(首字/总耗时、费用等);screenshot:提交的截图文件名。"""
    entry = {"id": rid, "time": time.strftime("%Y-%m-%d %H:%M:%S"), "text": "", "audio": "",
             "status": "ok", "error": "", "provider": "", "model": "", "app": "",
             "stats": None, "screenshot": "", "screenshot_note": ""}
    entry.update(fields)
    return entry


def add_history(entry, limit=100):
    """新增一条记录;超过保留条数(limit,0 为永久)时连同录音、截图一起删除最旧的。"""
    with _history_lock:
        items = [it for it in load_history() if it.get("id") != entry["id"]]
        items.insert(0, entry)
        _write_history(_prune(items, limit))


def update_history(rid, **fields):
    with _history_lock:
        items = load_history()
        for it in items:
            if it.get("id") == rid:
                it.update(fields)
        _write_history(items)


def apply_history_limit(limit):
    """调小保留条数时立即删掉多出来的旧记录。"""
    with _history_lock:
        _write_history(_prune(load_history(), limit))


def _prune(items, limit):
    if not limit or len(items) <= limit:
        return items
    for old in items[limit:]:
        _remove_files(old)
    return items[:limit]


def clear_history():
    """清理历史媒体及旧版训练素材；失败时保留历史索引并向调用方报告。"""
    with _history_lock:
        if os.path.isdir(RECORDINGS_DIR):
            with os.scandir(RECORDINGS_DIR) as entries:
                for entry in entries:
                    if entry.name == "training" and entry.is_dir(follow_symlinks=False):
                        # 只递归删除应用自己的旧训练目录，不碰其他子目录。
                        shutil.rmtree(entry.path)
                    elif entry.is_file(follow_symlinks=False) or entry.is_symlink():
                        os.remove(entry.path)
        try:
            os.remove(HISTORY_PATH)
        except FileNotFoundError:
            pass


def _remove_files(entry):
    for path in (recording_path(entry), screenshot_path(entry)):
        if path:
            try:
                os.remove(path)
            except OSError:
                pass


_RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
_RUN_NAME = "DaiwenVoiceInput"


def _pythonw():
    exe = sys.executable
    pyw = os.path.join(os.path.dirname(exe), "pythonw.exe")
    return pyw if os.path.exists(pyw) else exe


def create_desktop_shortcut():
    """在桌面创建 OneMore 快捷方式,返回路径。"""
    import subprocess

    def ps_quote(s):
        return "'" + s.replace("'", "''") + "'"

    script = f"""
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$desktop = [Environment]::GetFolderPath('Desktop')
$path = Join-Path $desktop '{APP_NAME}.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
$s.TargetPath = {ps_quote(_pythonw())}
$s.Arguments = '"' + {ps_quote(os.path.join(BASE_DIR, "main.pyw"))} + '"'
$s.WorkingDirectory = {ps_quote(BASE_DIR)}
$s.IconLocation = {ps_quote(ICON_PATH)}
$s.Description = '{APP_NAME} · 全模态语音输入'
$s.Save()
Write-Output $path
"""
    out = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        creationflags=subprocess.CREATE_NO_WINDOW, check=True)
    return out.stdout.strip()


_TASK_NAME = "DaiwenVoiceInput"
_TASK_XML = """<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>OneMore 语音输入:登录后以管理员权限启动</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>{user}</UserId><Delay>PT10S</Delay></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>{exe}</Command><Arguments>"{script}"</Arguments><WorkingDirectory>{cwd}</WorkingDirectory></Exec>
  </Actions>
</Task>
"""


def _schtasks(*args):
    import subprocess
    return subprocess.run(["schtasks", *args], capture_output=True, text=True,
                          encoding="oem", errors="replace",  # schtasks 按控制台代码页(GBK)输出
                          creationflags=subprocess.CREATE_NO_WINDOW)


def _remove_run_entry():
    """清理旧版写在 HKCU\\...\\Run 里的自启项(只能普通权限启动,已弃用)。"""
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, _RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, _RUN_NAME)
    except OSError:
        pass


def set_autostart(enabled):
    """用任务计划程序设置开机自启:登录 10 秒后以管理员权限启动,不弹 UAC 确认。
    创建需要管理员权限(程序以管理员身份运行时勾选即可)。失败时抛出带说明的异常。"""
    from xml.sax.saxutils import escape
    _remove_run_entry()
    if not enabled:
        _schtasks("/Delete", "/TN", _TASK_NAME, "/F")  # 不存在时报错,忽略
        return
    user = f"{os.environ.get('USERDOMAIN', '')}\\{os.environ.get('USERNAME', '')}"
    xml = _TASK_XML.format(user=escape(user), exe=escape(_pythonw()),
                           script=escape(os.path.join(BASE_DIR, "main.pyw")), cwd=escape(BASE_DIR))
    path = os.path.join(BASE_DIR, ".autostart_task.xml")
    with open(path, "w", encoding="utf-16") as f:
        f.write(xml)
    try:
        r = _schtasks("/Create", "/TN", _TASK_NAME, "/XML", path, "/F")
    finally:
        os.remove(path)
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip()
        if not is_admin():
            msg += "\n\n需要以管理员身份运行本程序后再勾选(右键桌面快捷方式 →“以管理员身份运行”)。"
        raise RuntimeError(msg)


def autostart_enabled():
    return _schtasks("/Query", "/TN", _TASK_NAME).returncode == 0


def is_admin():
    import ctypes
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False
