"""本机转写接口:让同一台电脑上的其他程序(目前是 本机调用方 的电话模式)借用输入法的引擎、提示词和个人词典转写。
约定见 ~/dev/eridian/docs/asr-bridge.md。

- 只监听 127.0.0.1;配置里没填 token 就不启动(防止本机任意程序白用 API 额度)。
- POST /v1/transcribe:请求体 16kHz 单声道 16 位 WAV,Authorization: Bearer <token>;
  查询参数 source / context / id / hotwords。返回 {"text","provider","model","ms"},没听到人话 {"text": ""}。
- GET /health:{"ok": true, "provider", "model"}。
- 只转写返回文字:不打字、不响提示音、不截图;历史里记一条(来源 source,程序信息写 context)。
- 每个请求在自己的线程里处理,不影响热键录音。日志不记识别文字。
"""
import copy
import io
import json
import logging
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
import soundfile as sf

import config
import recognition
from engine import MIN_VOICED_SECONDS, SAMPLE_RATE, encode_audio, trim_silence, voiced_seconds
from recognition import VoiceError

log = logging.getLogger("bridge")

MAX_BODY = 50 * 1024 * 1024
NO_SPEECH = ("没有识别到文字", "没有听清,请再说一次")


def _to_16k_mono(data):
    """WAV 字节 → 16kHz 单声道 int16(约定就是这个格式,别的采样率也尽量接住)。"""
    audio, rate = sf.read(io.BytesIO(data), dtype="int16", always_2d=True)
    audio = audio.mean(axis=1).astype(np.int16) if audio.shape[1] > 1 else audio[:, 0]
    if rate != SAMPLE_RATE:
        n = int(len(audio) * SAMPLE_RATE / rate)
        audio = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio).astype(np.int16)
    return audio


class Bridge:
    def __init__(self, engine):
        self.engine = engine
        self._server = None
        self._key = None

    def apply(self, cfg):
        """按配置启动/重启/停止(端口或 token 变了才重启)。"""
        token = str(cfg.get("asr_bridge_token", "")).strip()
        port = int(cfg.get("asr_bridge_port", 8095) or 8095)
        key = (port, token) if token else None
        if key == self._key:
            return
        self.stop()
        if key is None:
            return
        bridge = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass  # 不往标准输出写访问日志

            def _reply(self, status, obj):
                body = json.dumps(obj, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _authorized(self):
                return self.headers.get("Authorization", "") == f"Bearer {token}"

            def do_GET(self):
                if urlparse(self.path).path != "/health":
                    return self._reply(404, {"error": "not found"})
                p, _meta = config.active_provider(bridge.engine.cfg)
                self._reply(200, {"ok": True, "provider": bridge.engine.cfg["provider"], "model": p["model"]})

            def do_POST(self):
                url = urlparse(self.path)
                if url.path != "/v1/transcribe":
                    return self._reply(404, {"error": "not found"})
                if not self._authorized():
                    return self._reply(401, {"error": "unauthorized"})
                size = int(self.headers.get("Content-Length") or 0)
                if not 0 < size <= MAX_BODY:
                    return self._reply(400, {"error": "empty or too large body"})
                data = self.rfile.read(size)
                q = {k: v[0] for k, v in parse_qs(url.query).items()}
                status, obj = bridge.transcribe(data, q)
                self._reply(status, obj)

        try:
            self._server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        except OSError as e:
            log.warning("本机转写接口启动失败(端口 %d): %s", port, e)
            return
        self._server.daemon_threads = True
        self._key = key
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        log.info("本机转写接口已启动: 127.0.0.1:%d", port)

    def stop(self):
        server, self._server, self._key = self._server, None, None
        if server is not None:
            server.shutdown()
            server.server_close()

    def transcribe(self, data, q):
        """返回 (HTTP 状态码, JSON 对象)。"""
        start = time.monotonic()
        source = q.get("source", "") or "外部程序"
        context = q.get("context", "")
        cfg = copy.deepcopy(self.engine.cfg)
        cfg["strip_trailing_punct"] = False  # 给程序用,保留完整标点
        hotwords = [w for w in config.split_words(q.get("hotwords", "").replace(",", "，"))]
        if hotwords:
            config.add_words(cfg, hotwords, source="bridge")  # 只并进这一次的副本,不改用户词典
        p, _meta = config.active_provider(cfg)
        if not p["api_key"]:
            return 503, {"error": "输入法当前服务没有填 API Key"}
        try:
            audio = _to_16k_mono(data)
        except Exception:
            return 400, {"error": "无法读取 WAV"}
        base = {"provider": cfg["provider"], "model": p["model"]}
        voiced = voiced_seconds(audio)
        if voiced < MIN_VOICED_SECONDS:
            log.info("外部转写[%s %s]: 没有说话声(有声 %.2fs)", source, q.get("id", ""), voiced)
            return 200, {"text": "", **base, "ms": round((time.monotonic() - start) * 1000)}
        payload, fmt, _mime = encode_audio(trim_silence(audio))
        rid = config.new_record_id()
        entry = config.new_history_entry(rid, provider=cfg["provider"], model=p["model"],
                                         app=context or source, source=source)
        keep = cfg.get("history_enabled", True)
        if keep:
            try:
                entry["audio"] = config.save_recording(rid, payload, fmt)
                config.add_history(entry, cfg.get("history_limit", 100))
            except OSError:
                log.exception("外部转写: 保存历史失败")
        app = context if cfg.get("app_context", True) else ""
        try:
            text, stats = recognition.transcribe(cfg, payload, fmt, app, None, start)
            stats.pop("tail", None)
            fields = {"text": text, "status": "ok", "stats": stats}
            result = (200, {"text": text, **base})
        except VoiceError as e:
            msg = str(e)
            if msg in NO_SPEECH:
                fields, result = {"text": "", "status": "ok", "error": msg}, (200, {"text": "", **base})
            else:
                fields, result = {"status": "failed", "error": msg}, (502, {"error": msg})
        except Exception:
            log.exception("外部转写失败")
            fields, result = {"status": "failed", "error": "识别失败"}, (500, {"error": "识别失败"})
        ms = round((time.monotonic() - start) * 1000)
        if result[0] == 200:
            result[1]["ms"] = ms
        log.info("外部转写[%s %s]: %s %dms", source, q.get("id", ""), "完成" if result[0] == 200 else "失败", ms)
        if keep:
            try:
                config.update_history(rid, **fields)
            except Exception:
                log.exception("外部转写: 更新历史失败")
        self.engine.result.emit("")  # 刷新历史页
        return result
