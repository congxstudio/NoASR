"""核心引擎:热键监听、录音、提示音、静音裁剪、MP3 编码,把识别和流式回填串起来。"""
import copy
import ctypes
import io
import logging
import os
import re
import threading
import time
import wave
from ctypes import wintypes

import keyboard
import numpy as np
import sounddevice as sd
from PySide6.QtCore import QObject, Signal

import config
from password_guard import focused_is_password
import cues
import recognition
import screenshot
from shortcuts import MODIFIERS, key_ids, parse_hotkey
import audio_watch
from audio_watch import DeviceWatcher
from recognition import VoiceError
from streaming_input import ActivityMonitor, Destination, StreamingInput, key_input, send_inputs

SAMPLE_RATE = 16000
MIN_SECONDS = 0.4
MAX_SECONDS = 600  # 单次录音上限 10 分钟(两家实测约 12 分钟内都能完整转写)
CUE_DELAY = 0.15  # 按下热键后等这么久才响提示音:Ctrl+C 这类组合键两键间隔一般约 0.1 秒,期间按了别的键就取消不响
TAP_SECONDS = 0.4  # 短于此视为"单击",长于此视为"按住"
SCAN_ESC = 1
CONTINUE_SECONDS = 120  # 上一句打完后这么久以内、同一输入框、中间没按键没点鼠标,才算"接着说"
SHOT_MIN_VOICED = 1.5  # 有声不足这么多秒不附带截图:几乎没说话时附图,模型只会去念画面里的字(复述上一句的主要来源)
MIN_VOICED_SECONDS = 0.3  # 有声时长低于此值视为没说话(误触),不调用模型
WATCH_INTERVAL = 0.5   # 每隔多久检查一次麦克风插拔/默认设备变化
SILENT_PEAK = 8         # 整段录音最大幅度不超过它 = 数字静音(没插麦克风/被静音/虚拟设备);真麦克风底噪也有几百
STALL_SECONDS = 3.0    # 录音通道这么久没有回调,视为已失效(如麦克风被拔掉),自动重连

log = logging.getLogger("engine")
# PortAudio 重新初始化期间不能同时枚举设备、播放声音,统一用这把锁
_pa_lock = threading.RLock()


def play_file(path):
    """播放历史录音(非阻塞)。轻声录音自动放大(最多 18dB),不改原文件。"""
    import soundfile as sf
    data, rate = sf.read(path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    gain = cues.playback_gain(float(np.abs(data).max()) if len(data) else 0.0)
    with _pa_lock:
        sd.play(np.clip(data * gain, -1, 1).astype(np.float32), rate)


def _wasapi_output():
    """WASAPI(Windows 低延迟音频通道)下的默认输出设备序号,没有则返回 None。"""
    for i, api in enumerate(sd.query_hostapis()):
        if "WASAPI" in api["name"] and api["default_output_device"] >= 0:
            return api["default_output_device"]
    return None


def play_cue(start, style="bubble", volume=0.85):
    """提示音走 WASAPI 低延迟输出(约 3~10ms;老的 MME 默认缓冲约 180ms),失败时退回默认通道。
    输出和录音是两个独立的通道,播放不影响录音。"""
    data = cues.cue(style, start) * float(volume)
    try:
        with _pa_lock:
            device = _wasapi_output()
            if device is not None:
                sd.play(data, cues.RATE, device=device, latency="low",
                        extra_settings=sd.WasapiSettings(auto_convert=True))  # 由系统转换采样率和声道
                return
    except Exception:
        log.warning("低延迟通道播放提示音失败,改用默认通道", exc_info=True)
    try:
        with _pa_lock:
            sd.play(data, cues.RATE, latency="low")
    except Exception:
        log.exception("播放提示音失败")


def voiced_seconds(audio, frame_ms=20, threshold_db=-45.0):
    """音量超过阈值的总时长(秒)。用户正常说话至少 0.6 秒,静音误触为 0~0.1 秒。"""
    n = SAMPLE_RATE * frame_ms // 1000
    frames = len(audio) // n
    if frames == 0:
        return 0.0
    x = audio[: frames * n].astype(np.float32).reshape(frames, n) / 32768.0
    db = 20 * np.log10(np.sqrt((x ** 2).mean(axis=1)) + 1e-7)
    return float((db > threshold_db).sum() * frame_ms / 1000)


def trim_silence(audio, frame_ms=20, pad=0.25):
    """裁掉首尾静音:按帧算分贝,阈值取 max(-50dB, 底噪+10dB),首尾各保留 pad 秒。"""
    n = SAMPLE_RATE * frame_ms // 1000
    frames = len(audio) // n
    if frames < 5:
        return audio
    x = audio[: frames * n].astype(np.float32).reshape(frames, n) / 32768.0
    db = 20 * np.log10(np.sqrt((x ** 2).mean(axis=1)) + 1e-7)
    threshold = max(-50.0, np.percentile(db, 10) + 10)
    voiced = np.nonzero(db > threshold)[0]
    if len(voiced) == 0:
        return audio
    pad_frames = int(pad * 1000 / frame_ms)
    start = max(0, voiced[0] - pad_frames) * n
    end = min(frames, voiced[-1] + 1 + pad_frames) * n
    return audio[start:end]


def encode_audio(audio):
    """压缩为 16kHz 单声道 MP3(约 24kbps,体积约为 WAV 的 1/10);失败时退回 WAV。
    返回 (字节, format 字段, mime)。"""
    buf = io.BytesIO()
    try:
        import soundfile as sf
        sf.write(buf, audio, SAMPLE_RATE, format="MP3", subtype="MPEG_LAYER_III",
                 compression_level=0.9, bitrate_mode="CONSTANT")
        return buf.getvalue(), "mp3", "audio/mpeg"
    except Exception:
        log.exception("MP3 编码失败,改用 WAV")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(audio.tobytes())
    return buf.getvalue(), "wav", "audio/wav"


def _input_devices():
    """默认音频接口(MME)下的麦克风 [(序号, 名称)]。同一个麦克风在其他接口下会重复出现,只取一份。
    MME 的名称最多 31 个字,可能被截断。"声音映射器"是跟随系统默认的虚拟设备,不列出。"""
    api = sd.query_hostapis(sd.default.hostapi)
    out = []
    for i in api["devices"]:
        d = sd.query_devices(i)
        if d["max_input_channels"] > 0 and not re.match(r"Microsoft (声音映射器|Sound Mapper)", d["name"]):
            out.append((i, d["name"]))
    return out


def list_input_devices():
    """返回可用麦克风名称列表。"""
    try:
        with _pa_lock:
            return [name for _i, name in _input_devices()]
    except Exception:
        log.exception("枚举麦克风失败")
        return []


def default_input_name():
    """系统默认麦克风的名称(取不到时返回空字符串)。"""
    try:
        with _pa_lock:
            return sd.query_devices(kind="input")["name"]
    except Exception:
        return ""


AUTO_HINT = "自动：独立 USB 麦克风 > 耳机上的麦克风 > 电脑自带 > 蓝牙耳机，跳过没有声音的和虚拟设备"


def mic_choices(eng, current):
    """麦克风菜单项 [(配置值, 显示文字)]:第一项"自动",其余是各麦克风并标出类型。设置窗口和托盘共用。"""
    def kind(name):
        for full, rank in eng.mic_ranks.items():
            if full == name or (len(name) >= 31 and full.startswith(name)):
                return audio_watch.RANK_NAMES[rank]
        return ""
    using = eng.auto_name or eng.mic_name
    items = [("", f"自动（当前：{using}）" if using and not current else "自动（推荐）")]
    names = list_input_devices()
    items += [(n, f"{n}  ·  {kind(n)}" if kind(n) else n) for n in names]
    if current and current not in names:
        items.append((current, f"{current}（未连接）"))
    return items


def is_digital_silence(audio):
    """数字静音:没插麦克风的耳机接收器、被静音的麦克风送上来的几乎全是 0(只剩 ±1~2 的换算误差)。
    真麦克风哪怕没人说话也有环境和电路底噪,实测罗德约 -58dB、最大幅度几百,差距约 40dB。"""
    return len(audio) == 0 or int(np.abs(audio).max()) <= SILENT_PEAK


def probe_device(name, seconds=0.5):
    """打开某个麦克风听半秒:True 有声音,False 数字静音,None 打不开。
    共享模式打开,不影响正在用的录音通道和其他软件;全程持 _pa_lock,避免期间 PortAudio 被重建。"""
    with _pa_lock:
        index = resolve_device(name)
        if index is None:
            return None
        try:
            st = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="int16", device=index)
            st.start()
            try:
                data, _ = st.read(int(SAMPLE_RATE * (seconds + 0.1)))
            finally:
                st.stop()
                st.close()
        except Exception:
            log.warning("检测麦克风失败: %s", name, exc_info=True)
            return None
    return not is_digital_silence(data[int(SAMPLE_RATE * 0.1):, 0])  # 丢掉刚打开的 0.1 秒


def resolve_device(name):
    """按名称找麦克风序号,找不到返回 None(用系统默认)。
    兼容旧配置里其他接口下的完整名称:MME 名称被截断,按前缀匹配。"""
    if not name:
        return None
    devices = _input_devices()
    for i, n in devices:
        if n == name:
            return i
    for i, n in devices:
        if len(n) >= 31 and name.startswith(n):
            return i
    return None


def _is_right(event):
    """左右 Ctrl/Alt 的扫描码相同(29/56),只能靠名称区分:右侧键叫 "right ctrl"/"right alt"。"""
    return (event.name or "").startswith("right ")


def _key_ids(name):
    """热键里的一个键 → 可接受的 (扫描码, 是否右侧键) 集合。
    写明 right/left 的只认那一侧;只写 ctrl/alt/shift 的左右都算(和以前一样)。"""
    return key_ids(name)


class Engine(QObject):
    level = Signal(float)         # 当前音量 0~1
    state = Signal(str, str)      # 状态(recording/processing/error/idle), 提示文字
    result = Signal(str)          # 识别出的文字(失败时为空,用于刷新历史)
    anchor = Signal(object)       # 本次录音的胶囊定位信息(触发时的窗口范围、鼠标位置)
    copy_text = Signal(str)       # 需要写入剪贴板的文字(回填没完成时复制全文)
    fast_disabled = Signal()      # 火山 Fast 未开通,已自动关闭开关
    wrote = Signal(object)        # 一句话完整打进去了:{"text","hwnd","focus","app"},供"从修改中学习"
    user_input = Signal(str, object)  # 用户真实按键/点击(不含说话热键):种类, 鼠标位置或 None
    dictionary_hits = Signal(str)     # 识别结果文字,界面层据此记录词条命中时间
    retry_done = Signal(str, str, str)  # 记录 id, 文字, 错误信息
    mic_changed = Signal(str)     # 实际使用的麦克风换了(名称;为空表示没有可用麦克风)

    def __init__(self, cfg):
        super().__init__()
        self.cfg = cfg
        self._frames = []
        self._recording = False
        self._stream = None
        self._hook = None
        self._combo = []       # 每个按键对应的 (扫描码, 是否右侧键) 集合,如 right ctrl+space -> [{(29, True)…}, {(57, False)…}]
        self._pressed = set()  # 当前按下的 (扫描码, 是否右侧键)
        self._modifier_keys = set()
        self._held = False     # 热键组合当前是否处于按下状态
        self._press_t = 0.0    # 本次按下热键的时间
        self._toggle = False   # 是否处于单击切换的录音中(松开热键后继续录)
        self._samples = 0      # 本次已录采样数
        self._auto_ending = False  # 已触发录满上限的自动提交
        self._external = False     # 本次录音是否由外部(鼠标长按)触发
        self._send_enter = False   # 本次输入完后是否自动回车发送
        self._app = ""         # 本次录音时的前台程序描述
        self._dest = None      # 本次录音开始时的输入目标
        self._shot = None      # 本次录音的后台截图任务
        self._session = None   # 本次录音用的设置快照(录音中改设置不影响这一次)
        self._lock = threading.Lock()
        self._stream_lock = threading.RLock()  # 打开/关闭/重建录音通道
        self._last_audio = 0.0  # 录音通道最近一次回调的时间,用来发现通道失效
        self.mic_name = ""     # 当前实际使用的麦克风
        self._last_text = None  # 上一条识别结果,复述守卫用(None 表示还没从历史读过)
        self._cont = None       # 上一句打完时的位置:{"hwnd","focus","time","tail","last"},接着说时补标点用
        self._user_input_at = 0.0  # 最近一次用户真实按键/点鼠标的时间(不含说话热键)
        self._ignore_keys_until = 0.0  # 程序自己模拟按键(如 Ctrl+C 读选中文字)期间,热键状态机不响应
        self._activity = None
        self.auto_name = None  # "自动"模式下挑中的麦克风(None 表示交给系统默认)
        self.mic_ranks = {}    # 麦克风名称 -> 类型(audio_watch.RANK_*),界面显示用
        self._recheck = False  # 需要重新挑麦克风(如刚录到数字静音)
        self._watching = False

    # ---------- 生命周期 ----------
    def start(self):
        # 全程监听真实的按键和鼠标点击(自己注入的不算),判断两句之间用户有没有动过输入框
        self._activity = ActivityMonitor(self._on_user_input)
        if not self.cfg["device"]:
            try:
                self._pick_auto(DeviceWatcher())  # 启动时先挑好,免得一开始用错麦克风又切换
            except Exception:
                log.exception("自动选择麦克风失败")
        self._open_stream()
        self._register_hotkey()
        self._watching = True
        threading.Thread(target=self._watch_devices, daemon=True).start()

    def stop(self):
        if self._activity:
            self._activity.stop()
        self._watching = False
        self._unregister_hotkey()
        self._close_stream()

    def suspend_hotkey(self):
        """打开设置时暂停热键,避免录入热键时触发录音。"""
        if self._recording:
            self._cancel()
        self._unregister_hotkey()

    def resume_hotkey(self):
        self._unregister_hotkey()
        self._register_hotkey()

    def apply_config(self, cfg):
        old = self.cfg
        self.cfg = cfg
        if old["device"] != cfg["device"]:
            if not cfg["device"]:
                self._recheck = True  # 切到"自动":后台线程马上重新挑选
            self._reload_audio("切换麦克风设置")

    def _on_user_input(self, kind, scan, pt=None):
        if scan is not None and any(scan == k[0] for keys in self._combo for k in keys):
            return  # 说话热键本身不算
        self._user_input_at = time.monotonic()
        self._user_input_what = kind if scan is None else f"{kind}(扫描码 {scan})"
        self.user_input.emit(kind, pt)

    def ignore_keys(self, seconds):
        """接下来一小段时间里热键状态机不响应按键(程序自己模拟 Ctrl 组合键时,别误触发录音)。"""
        self._ignore_keys_until = time.monotonic() + seconds

    def _continuation_prefix(self, dest):
        """这一句是不是接着上一句在同一个地方说;是的话返回"补前缀"的函数,否则 None。
        补回上一句被去掉的末尾标点;两边都是英文字母/数字时补空格,避免粘成一个词。"""
        c = self._cont
        reason = ("上一句没有完整打进去或已自动发送" if not c else "拿不到输入位置" if dest is None
                  else "换了窗口" if dest.hwnd != c["hwnd"] else "换了输入框" if dest.focus != c["focus"]
                  else "隔得太久" if time.monotonic() - c["time"] > CONTINUE_SECONDS
                  else f"中间有{getattr(self, '_user_input_what', '操作')}" if self._user_input_at > c["time"] else "")
        if reason:
            log.info("不补标点: %s", reason)
            return None

        def prefix(first):
            tail, last, nxt = c["tail"], c["last"], first[:1]
            latin = lambda ch: ch.isascii() and ch.isalnum()
            if tail:
                return tail + (" " if tail[-1] in ".,!?;:" and latin(nxt) else "")
            return " " if latin(last) and latin(nxt) else ""
        log.info("接着上一句说,补回标点/空格")
        return prefix

    # ---------- 热键 ----------
    def _register_hotkey(self):
        """支持单键或组合键(如 ctrl+space):全部按下开始录音,松开其中任意一个结束。"""
        hk = self.cfg["hotkey"]
        try:
            self._combo = parse_hotkey(hk)[1]
            self._modifier_keys = set().union(*(key_ids(k) for k in MODIFIERS))
            if not self._combo:
                raise ValueError("热键为空")
            self._pressed = set()
            self._hook = keyboard.hook(self._on_key)
        except Exception as e:
            log.exception("注册热键失败")
            self.state.emit("error", f"热键无效: {hk} ({e})")

    def _unregister_hotkey(self):
        if self._hook is not None:
            try:
                keyboard.unhook(self._hook)
            except Exception:
                pass
            self._hook = None
        self._pressed.clear()
        self._held = False

    def _on_key(self, event):
        """热键状态机。按下即开始录音,松开时按录音方式决定:
        hold 按住说话 → 松开提交;toggle 单击切换 → 继续录音,再按一次提交;
        both → 短按(< TAP_SECONDS)走单击切换,长按走按住说话。"""
        if time.monotonic() < self._ignore_keys_until:
            return
        code = (event.scan_code, _is_right(event))
        in_combo = any(code in keys for keys in self._combo)
        if event.event_type == keyboard.KEY_DOWN:
            self._pressed.add(code)
            if not in_combo:
                if (self._toggle or self._external) and code[0] == SCAN_ESC:
                    self._cancel()
                elif self._held:
                    self._cancel()  # 按着热键时按了别的键,视为在用快捷键(如 Ctrl+S)
                return
            if self._held or not all(keys & self._pressed for keys in self._combo):
                return  # 按住时的自动重复,或组合键还没按全
            if any(k in self._modifier_keys and not any(k in group for group in self._combo)
                   for k in self._pressed):
                return  # 多按了其他修饰键,属于另一组快捷键。
            self._held = True
            self._press_t = time.time()
            if "alt" in self.cfg["hotkey"].lower():
                # 每次按下都要打断(不只开始录音那一下):点按模式再点一次结束时,松开 Alt 同样会
                # 激活目标窗口菜单栏,随后打的字全进了菜单,输入框里什么都没有
                cancel_menu_activation()
            if self._toggle:
                self._end()  # 单击切换模式下再按一次:提交
            elif not self._recording:
                self._begin()
        else:
            self._pressed.discard(code)
            if not (in_combo and self._held):
                return
            self._held = False
            if not self._recording or self._toggle:
                return
            mode = self.cfg.get("mode", "both")
            short = time.time() - self._press_t < TAP_SECONDS
            if mode == "toggle" or (mode == "both" and short):
                self._toggle = True
                self.state.emit("recording", "再按一次结束 · Esc 取消")
            else:
                self._end()

    def _cancel(self):
        with self._lock:
            self._recording = False
            self._toggle = False
            self._frames = []
            if self._shot:
                self._shot.cancel()
                self._shot = None
        self.state.emit("idle", "")

    # ---------- 录音 ----------
    # 录音通道启动后一直开着(按热键即可开录,不丢开头的字)。后台线程负责发现麦克风插拔、
    # 系统默认麦克风切换、通道失效,并在需要时重建通道。
    def _open_stream(self, quiet=False):
        with self._stream_lock:
            try:
                with _pa_lock:
                    manual = self.cfg["device"]
                    wanted = manual or self.auto_name
                    device = resolve_device(wanted)
                    if manual and device is None:
                        log.warning("设置的麦克风未连接,改用系统默认")
                    self._stream = sd.InputStream(
                        samplerate=SAMPLE_RATE, channels=1, dtype="int16",
                        device=device, callback=self._on_audio)
                    self._last_audio = time.time()
                    self._stream.start()
                    name = sd.query_devices(self._stream.device)["name"]
                    if re.match(r"Microsoft (声音映射器|Sound Mapper)", name):
                        name = "系统默认"
            except Exception as e:
                log.exception("打开麦克风失败")
                self._stream = None
                name = ""
                if not quiet:
                    self.state.emit("error", f"无法打开麦克风: {e}")
            if name != self.mic_name:
                log.info("使用麦克风: %s", name or "(无)")
                self.mic_name = name
                self.mic_changed.emit(name)

    def _close_stream(self):
        with self._stream_lock:
            if self._stream is not None:
                try:
                    self._stream.stop()
                    self._stream.close()
                except Exception:
                    pass
                self._stream = None

    def _reload_audio(self, reason):
        """重新初始化 PortAudio(刷新设备列表)并重建录音通道。录音中调用时,新通道的声音接着录。"""
        log.info("重建录音通道: %s", reason)
        with self._stream_lock:
            self._close_stream()
            try:
                with _pa_lock:
                    sd.stop()  # 先停掉可能在播放的提示音
                    sd._terminate()
                    sd._initialize()
            except Exception:
                log.exception("重新初始化音频失败")
            self._open_stream(quiet=True)

    def _stream_dead(self):
        st = self._stream
        if st is None:
            return True
        try:
            return not st.active or time.time() - self._last_audio > STALL_SECONDS
        except Exception:
            return True

    def _pick_auto(self, watcher):
        """"自动"选麦克风:按 独立麦克风 > 耳机麦克风 > 电脑自带 > 蓝牙耳机 的顺序,挑第一个有声音的。
        虚拟设备不自动选;蓝牙耳机打开麦克风会切到通话模式、音质变差,所以不去检测,直接排最后。
        都没声音时(可能都被静音)仍选优先级最高的。返回挑选结果是否变化。"""
        devices = watcher.capture_devices()
        self.mic_ranks = {d["name"]: d["rank"] for d in devices}
        candidates = [d for d in devices if d["rank"] < audio_watch.RANK_VIRTUAL]
        chosen, skipped = None, []
        for d in candidates:
            if d["rank"] == audio_watch.RANK_BLUETOOTH or probe_device(d["name"]):
                chosen = d
                break
            skipped.append(d["name"])
        note = f",跳过没有声音的: {'、'.join(skipped)}" if skipped else ""
        if chosen is None and candidates:
            chosen = candidates[0]
            note = ",所有麦克风都没有声音(可能都被静音),先用优先级最高的"
        name = chosen["name"] if chosen else None
        log.info("自动选择麦克风: %s(%s)%s", name or "系统默认",
                 audio_watch.RANK_NAMES[chosen["rank"]] if chosen else "没有可自动选择的麦克风", note)
        changed, self.auto_name = name != self.auto_name, name
        return changed

    def _watch_devices(self):
        try:
            watcher = DeviceWatcher()
            last = watcher.capture_signature()
            self.mic_ranks = {d["name"]: d["rank"] for d in watcher.capture_devices()}
        except Exception:
            log.exception("无法监听麦克风变化")
            watcher = last = None
        while self._watching:
            time.sleep(WATCH_INTERVAL)
            try:
                changed = False
                if watcher is not None:
                    sig = watcher.capture_signature()
                    if sig != last:
                        log.info("检测到音频设备变化: 默认麦克风%s, 已连接麦克风 %d → %d 个, 默认输出%s",
                                 "已变" if sig[0] != last[0] else "未变", len(last[1]), len(sig[1]),
                                 "已变" if sig[2] != last[2] else "未变")
                        last = sig
                        changed = True
                        self.mic_ranks = {d["name"]: d["rank"] for d in watcher.capture_devices()}
                auto = not self.cfg["device"]
                if auto and (changed or self._recheck) and watcher is not None and not self._recording:
                    # "自动"模式:设备变了或刚录到无声,重新挑一次(要打开各麦克风听半秒,录音中不做)
                    self._recheck = False
                    if self._pick_auto(watcher) or changed:
                        self._reload_audio("设备变化" if changed else "自动重新选择麦克风")
                elif changed:
                    # 录音中也立即切换(重建约几十毫秒,声音接着录):刚插上的麦克风正是用户要用的
                    if auto:
                        self._recheck = True  # 录完再按优先级重新挑
                    self._reload_audio("设备变化")
                elif self._stream is not None and self._stream_dead():
                    self._reload_audio("录音通道失效")
            except Exception:
                log.exception("检查麦克风状态出错")

    def _on_audio(self, indata, _frames, _time, _status):
        self._last_audio = time.time()
        if not self._recording:
            return
        self._frames.append(indata.copy())
        self._samples += len(indata)
        if self._samples >= SAMPLE_RATE * MAX_SECONDS and not self._auto_ending:
            self._auto_ending = True
            threading.Thread(target=self._end, daemon=True).start()  # 录满上限自动提交
        rms = float(np.sqrt(np.mean(indata.astype(np.float32) ** 2))) / 32768.0
        # 按分贝映射:约 -55dB(安静)→0,约 -15dB(大声)→1
        db = 20 * np.log10(rms + 1e-7)
        self.level.emit(float(min(1.0, max(0.0, (db + 55) / 40))))

    # ---------- 外部触发(鼠标长按等),固定按"按住说话"语义 ----------
    def begin_external(self):
        self._begin(cue_delay=0, external=True)  # 长按判定已经等过 0.5 秒,提示音立即响

    def end_external(self, send_enter=False):
        """send_enter:输入完文字后再按一次回车(长按时点了右键)。"""
        self._send_enter = send_enter
        self._end()

    def mark_send(self):
        """长按录音中点了右键:提示用户松开后会自动发送。"""
        if self._recording:
            self.state.emit("recording", "松开左键后发送")

    def cancel_external(self):
        if self._recording:
            self._cancel()

    def _begin(self, cue_delay=CUE_DELAY, external=False):
        if focused_is_password():
            self.state.emit("error", "受保护输入框中不启动语音")
            return
        with self._lock:
            if self._recording:
                return
            if self._stream_dead():
                self._reload_audio("开始录音时发现通道不可用")
                if self._stream is None:
                    self.state.emit("error", "没有可用的麦克风")
                    return
            p, meta = config.active_provider(self.cfg)
            if not p["api_key"]:
                self.state.emit("error", f"请先填写{meta['name']}的 API Key")
                return
            self._session = copy.deepcopy(self.cfg)
            self._frames = []
            self._samples = 0
            self._toggle = False
            self._external = external  # 鼠标长按等外部触发,Esc 可取消
            self._auto_ending = False
            self._recording = True
        cfg = self._session
        # 按下热键时记下前台程序、输入目标和窗口位置(识别完成时焦点可能已变)
        hwnd = ctypes.windll.user32.GetForegroundWindow()
        pointer = screenshot.cursor_pos()
        self._dest = Destination.capture()
        if self._shot:
            self._shot.cancel()
        self._shot = screenshot.ScreenshotJob(hwnd, pointer) if cfg.get("window_screenshot") else None
        self._app = describe_app(*get_foreground_app()) if cfg.get("app_context", True) else ""
        own = _window_pid(hwnd) == os.getpid()
        self.anchor.emit({"mode": cfg.get("overlay_position", "window"), "pointer": pointer,
                          "window": None if own else screenshot.window_rect(hwnd)})
        self.state.emit("recording", "")
        # 与悬浮条一样延迟一点再响,避免 Ctrl+C 这类误触也发声
        threading.Timer(cue_delay, self._start_cue).start()

    def _start_cue(self):
        if not self._recording:
            return
        cfg = self._session or self.cfg
        recognition.network.warmup(cfg["provider"], config.active_provider(cfg)[0])  # 确认不是误触后再预热连接
        if cfg.get("sound", True):
            play_cue(True, cfg.get("sound_style", "bubble"), cfg.get("sound_volume", 0.85))

    def _end(self):
        with self._lock:
            if not self._recording:
                return
            self._recording = False
            self._toggle = False
            frames, self._frames = self._frames, []
            job, self._shot = self._shot, None
        origin = time.monotonic()  # 耗时统计从结束录音算起
        cfg = self._session or self.cfg
        if not frames:
            self.state.emit("idle", "")
            return
        audio = np.concatenate(frames)[: SAMPLE_RATE * MAX_SECONDS]
        if len(audio) / SAMPLE_RATE < MIN_SECONDS:
            if job:
                job.cancel()
            self.state.emit("idle", "")  # 误触(如 Ctrl+C)静默丢弃
            return
        if cfg.get("sound", True):
            play_cue(False, cfg.get("sound_style", "bubble"), cfg.get("sound_volume", 0.85))
        self.state.emit("processing", "识别中")
        send, self._send_enter = self._send_enter, False
        threading.Thread(target=self._process, daemon=True,
                         args=(cfg, audio, self._app, send, self._dest, job, origin)).start()

    # ---------- 识别与输入 ----------
    def _process(self, cfg, audio, app, send_enter, dest, job, origin):
        raw_seconds = len(audio) / SAMPLE_RATE
        voiced = voiced_seconds(audio)
        if voiced < MIN_VOICED_SECONDS:
            # 没说话(误触、按了热键没出声):不调用模型,静默丢弃。
            # 否则模型"听"不到内容,会把提示词当成内容复述出来
            if job:
                job.cancel()
            if raw_seconds >= 1.0 and is_digital_silence(audio):
                # 录到的是数字静音:不是没说话,而是这个麦克风根本没声音(没插好/被静音)
                log.info("录到数字静音(共 %.1fs),麦克风可能没插好或被静音: %s", raw_seconds, self.mic_name)
                if not cfg["device"]:
                    self._recheck = True  # "自动"模式:马上重新挑一个有声音的麦克风
                self.state.emit("error", "麦克风没有声音，可能没插好或被静音")
                return
            log.info("未检测到说话声(有声 %.2fs / 共 %.1fs),按误触丢弃", voiced, raw_seconds)
            self.state.emit("idle", "")
            return
        audio = trim_silence(audio)
        payload, fmt, _mime = encode_audio(audio)
        log.info("音频 %.1fs→裁剪后%.1fs, %s %.1fKB", raw_seconds, len(audio) / SAMPLE_RATE,
                 fmt, len(payload) / 1024)
        keep = cfg.get("history_enabled", True)
        limit = cfg.get("history_limit", 100)
        p, _meta = config.active_provider(cfg)
        rid = config.new_record_id()
        entry = config.new_history_entry(rid, provider=cfg["provider"], model=p["model"], app=app)
        jpeg = None
        if job and voiced < SHOT_MIN_VOICED:
            job.cancel()
            job = None
            log.info("有声 %.1f 秒,不带截图", voiced)
        if job:
            jpeg, _source, note = job.value()
            entry["screenshot_note"] = note
            if jpeg and not config.supports_screenshot(cfg["provider"], p["model"]):
                jpeg, entry["screenshot_note"] = None, "当前模型不支持音频与截图组合，本次仅使用录音"
        if self._last_text is None:
            self._last_text = next((it.get("text", "") for it in config.load_history() if it.get("text")), "")
        previous = self._last_text
        if keep:
            try:
                entry["audio"] = config.save_recording(rid, payload, fmt)
                if jpeg:
                    entry["screenshot"] = config.save_recording(rid, jpeg, "jpg")
                config.add_history(entry, limit)
                self.result.emit("")
            except OSError:
                log.exception("保存录音或历史失败")
        writer = StreamingInput(dest, origin, self.copy_text.emit, previous_text=previous,
                                prefix=self._continuation_prefix(dest))
        self._cont = None  # 这一句开始回填后,旧的"接着说"信息作废
        try:
            text, stats = recognition.transcribe(
                cfg, payload, fmt, app, jpeg, origin, on_text=writer.push,
                on_fast_unavailable=self._disable_fast)
        except Exception as e:
            writer.abort()
            if isinstance(e, VoiceError):
                msg = str(e)
                log.info("识别失败: %s", msg)
            else:
                msg = "识别失败,可在历史记录中重试"
                log.exception("识别失败")
            self._save_result(keep, entry, text=writer.received, status="failed", error=msg)
            self.state.emit("error", msg)
            return
        writer.finish(send_enter, text)
        tail = stats.pop("tail", "")
        log.info("识别完成 %s/%s 首字%.2fs 总%.2fs 回填%s", cfg["provider"], p["model"],
                 stats["first"] or 0, stats["total"], "完成" if writer.failure is None else "中断")
        if writer.echo_blocked:
            self._save_result(keep, entry, text=text, status="ok", stats=stats,
                              error="与上一条几乎相同,判定为模型复述画面,未输入")
            self.state.emit("error", "和上一句一样，没有输入")
            return
        self._last_text = text
        if writer.failure is None and writer.wrote_first and not writer.sent_enter and dest is not None:
            # 完整打进去了且没有自动发送:记住位置,下一句接着说时补回末尾标点
            self._cont = {"hwnd": dest.hwnd, "focus": dest.focus, "time": time.monotonic(),
                          "tail": tail if cfg.get("strip_trailing_punct") else "", "last": text[-1:]}
        self._save_result(keep, entry, text=text, status="ok", error=writer.failure or "", stats=stats)
        self.dictionary_hits.emit(text)
        if writer.failure is None and writer.wrote_first and dest is not None:
            self.wrote.emit({"text": text, "hwnd": dest.hwnd, "focus": dest.focus, "app": (app or "").split("（")[0]})
        if writer.copied:
            self.state.emit("copied", "partial" if writer.wrote_first else "")
        elif writer.failure:
            self.state.emit("error", writer.failure)
        elif stats.get("fast_fallback"):
            self.state.emit("notice", "Fast 未开通，已用常规档")
        else:
            self.state.emit("idle", "")

    def _save_result(self, keep, entry, **fields):
        """更新历史;任何异常只记日志,不影响转写结果。"""
        entry.update(fields)
        if keep:
            try:
                config.update_history(entry["id"], **fields)
            except Exception:
                log.exception("写入历史记录失败")
        self.result.emit(entry.get("text", ""))

    def _disable_fast(self):
        """火山 Fast 未开通:关掉开关并保存,本次自动改用常规档。"""
        if self.cfg.get("volcano_fast"):
            self.cfg["volcano_fast"] = False
            try:
                config.save_config(self.cfg)
            except OSError:
                log.exception("保存设置失败")
            self.fast_disabled.emit()

    def retranscribe(self, entry):
        """用当前服务商重新识别历史记录里的录音(沿用当时的程序信息和截图),完成后发出 retry_done。"""
        cfg = copy.deepcopy(self.cfg)

        def run():
            p, _meta = config.active_provider(cfg)
            origin = time.monotonic()
            try:
                path = config.recording_path(entry)
                if not path or not os.path.exists(path):
                    raise VoiceError("录音文件不存在")
                with open(path, "rb") as f:
                    payload = f.read()
                jpeg = None
                shot = config.screenshot_path(entry)
                if shot:
                    if not os.path.exists(shot):
                        raise VoiceError("原截图文件不存在，无法使用原始上下文重新识别")
                    with open(shot, "rb") as f:
                        jpeg = f.read()
                    if not config.supports_screenshot(cfg["provider"], p["model"]):
                        jpeg = None
                fmt = os.path.splitext(path)[1].lstrip(".").lower()
                app = entry.get("app", "") if cfg.get("app_context", True) else ""
                text, stats = recognition.transcribe(cfg, payload, fmt, app, jpeg, origin)
                stats.pop("tail", None)
                stats["retried"] = True
            except Exception as e:
                msg = str(e) if isinstance(e, VoiceError) else "识别失败"
                log.info("重新识别失败: %s", msg)
                config.update_history(entry["id"], error="重新识别失败：" + msg)
                self.retry_done.emit(entry["id"], "", msg)
                return
            config.update_history(entry["id"], text=text, status="ok", error="", stats=stats,
                                  provider=cfg["provider"], model=p["model"])
            self.retry_done.emit(entry["id"], text, "")

        threading.Thread(target=run, daemon=True).start()


def _window_pid(hwnd):
    pid = wintypes.DWORD()
    ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


_VK_DUMMY = 0xFF  # 未分配的虚拟键,用来打断 Alt 单击激活菜单栏


# 常用软件的中文名(键为小写程序名),对照表里没有的再读程序文件自带的"文件说明"
APP_NAMES = {
    "wechat.exe": "微信", "weixin.exe": "微信", "wxwork.exe": "企业微信",
    "qq.exe": "QQ", "tim.exe": "TIM", "dingtalk.exe": "钉钉",
    "feishu.exe": "飞书", "lark.exe": "飞书", "telegram.exe": "Telegram",
    "winword.exe": "Word 文档", "excel.exe": "Excel 表格", "powerpnt.exe": "PowerPoint 演示文稿",
    "outlook.exe": "Outlook 邮件", "onenote.exe": "OneNote 笔记", "foxmail.exe": "Foxmail 邮件",
    "wps.exe": "WPS 文字", "et.exe": "WPS 表格", "wpp.exe": "WPS 演示",
    "chrome.exe": "Chrome 浏览器", "msedge.exe": "Edge 浏览器", "firefox.exe": "Firefox 浏览器",
    "360se.exe": "360 浏览器", "qqbrowser.exe": "QQ 浏览器",
    "code.exe": "VS Code 代码编辑器", "cursor.exe": "Cursor 代码编辑器",
    "windsurf.exe": "Windsurf 代码编辑器", "idea64.exe": "IntelliJ IDEA 代码编辑器",
    "pycharm64.exe": "PyCharm 代码编辑器",
    "windowsterminal.exe": "Windows 终端", "cmd.exe": "命令提示符",
    "powershell.exe": "PowerShell 终端", "pwsh.exe": "PowerShell 终端",
    "notepad.exe": "记事本", "notepad++.exe": "Notepad++ 文本编辑器",
    "explorer.exe": "文件资源管理器", "obsidian.exe": "Obsidian 笔记", "notion.exe": "Notion 笔记",
    "claude.exe": "Claude AI 助手", "chatgpt.exe": "ChatGPT AI 助手", "codex.exe": "Codex AI 编程助手",
}
_desc_cache = {}


def _file_description(path):
    """读取 exe 版本信息里的 FileDescription(如 notepad.exe → 记事本),带缓存。"""
    if path in _desc_cache:
        return _desc_cache[path]
    desc = ""
    try:
        ver = ctypes.windll.version
        size = ver.GetFileVersionInfoSizeW(path, None)
        buf = ctypes.create_string_buffer(size) if size else None
        if buf and ver.GetFileVersionInfoW(path, 0, size, buf):
            p, n = ctypes.c_void_p(), wintypes.UINT()
            langs = []
            if ver.VerQueryValueW(buf, r"\VarFileInfo\Translation", ctypes.byref(p), ctypes.byref(n)) and n.value:
                arr = (wintypes.WORD * (n.value // 2)).from_address(p.value)
                langs = [f"{arr[i]:04x}{arr[i + 1]:04x}" for i in range(0, len(arr) - 1, 2)]
            for lang in langs + ["080404b0", "040904b0", "040904e4"]:
                key = rf"\StringFileInfo\{lang}\FileDescription"
                if ver.VerQueryValueW(buf, key, ctypes.byref(p), ctypes.byref(n)) and n.value:
                    desc = ctypes.wstring_at(p.value, n.value).rstrip("\x00").strip()
                    break
    except Exception:
        log.exception("读取文件说明失败")
    _desc_cache[path] = desc
    return desc


def get_foreground_app():
    """返回当前前台窗口的 (显示名, 窗口标题);是本程序自己或获取失败时返回 ("", "")。
    显示名优先用中文对照表,其次用程序的文件说明,最后用程序名。"""
    user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
    try:
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return "", ""
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value == os.getpid():
            return "", ""
        title = ctypes.create_unicode_buffer(256)
        user32.GetWindowTextW(hwnd, title, 256)
        exe = ""
        handle = kernel32.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
        if handle:
            try:
                buf = ctypes.create_unicode_buffer(1024)
                size = wintypes.DWORD(1024)
                if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                    exe = buf.value
            finally:
                kernel32.CloseHandle(handle)
        name = ""
        if exe:
            base = os.path.basename(exe)
            name = APP_NAMES.get(base.lower()) or _file_description(exe) or os.path.splitext(base)[0]
        return name, title.value.strip()[:80]
    except Exception:
        log.exception("获取前台程序失败")
        return "", ""


def describe_app(name, title):
    """拼成"微信（窗口：文件传输助手）";标题和程序名相同时只保留程序名。"""
    if not name and not title:
        return ""
    if not title or title == name:
        return name
    return f"{name}（窗口：{title}）" if name else f"窗口：{title}"


def cancel_menu_activation():
    """插入一次无效按键,避免松开 Alt 时目标窗口激活菜单栏。"""
    send_inputs([key_input(vk=_VK_DUMMY), key_input(vk=_VK_DUMMY, flags=0x0002)])


def service_check(cfg):
    """用系统中文语音合成一句"今天天气不错",实际走一遍识别,返回给用户看的结果。"""
    import tempfile
    import comtypes
    import comtypes.client
    import soundfile as sf
    path = os.path.join(tempfile.gettempdir(), f"voice-check-{os.getpid()}.wav")
    try:
        comtypes.CoInitialize()
        voice = comtypes.client.CreateObject("SAPI.SpVoice")
        stream = comtypes.client.CreateObject("SAPI.SpFileStream")
        fmt = comtypes.client.CreateObject("SAPI.SpAudioFormat")
        fmt.Type = 18  # 16kHz 16bit 单声道
        stream.Format = fmt
        stream.Open(path, 3)
        voice.AudioOutputStream = stream
        voice.Speak("今天天气不错")
        stream.Close()
        audio, _rate = sf.read(path, dtype="int16")
    except Exception:
        log.exception("合成测试语音失败")
        return "无法合成测试语音"
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    payload, fmt_name, _mime = encode_audio(audio)
    t0 = time.monotonic()
    try:
        text, stats = recognition.transcribe(cfg, payload, fmt_name, "", None, t0)
    except VoiceError as e:
        return f"没通：{e}"
    except Exception:
        log.exception("测试连接失败")
        return "没通：未知错误"
    prefix = "Fast 未开通，已改用常规档。" if stats.get("fast_fallback") else ""
    return f"{prefix}通了，{time.monotonic() - t0:.1f} 秒 · 听到：{text[:20]}"
