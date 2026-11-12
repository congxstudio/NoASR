"""程序内合成的提示音,五种音色,与 macos/Sources/Cues.swift 的合成算法一致。开始音偏高、结束音偏低。"""
import numpy as np

RATE = 24000
LEAD = 0.03  # 开头留一点空白,避免声卡刚唤醒时吞掉起音
G5, B5, C6, E6 = 783.99, 987.77, 1046.5, 1318.5


def _env(t, attack, decay):
    return np.where(t < 0, 0.0, np.minimum(1.0, np.maximum(t, 0) / attack) * np.exp(-np.maximum(t, 0) / decay))


def _marimba(t, f):
    return _env(t, 0.003, 0.07) * np.sin(2 * np.pi * f * t) \
        + 0.25 * _env(t, 0.002, 0.02) * np.sin(2 * np.pi * 4 * f * t)


def _bubble(t, f0, f1):
    slide = 0.07
    k = np.log(f1 / f0) / slide
    tc = np.clip(t, 0, None)
    phase = f0 * (np.exp(k * np.minimum(tc, slide)) - 1) / k + np.where(tc <= slide, 0, f1 * (tc - slide))
    v = _env(t, 0.004, 0.045) * np.sin(2 * np.pi * phase)
    return np.where((t >= 0) & (t <= 0.16), v, 0.0)


def _bell(t, f):
    # 调制深度随时间衰减,起音带一点金属感,尾音变纯
    tc = np.clip(t, 0, None)
    depth = 1.6 * np.exp(-tc / 0.08)
    v = _env(t, 0.004, 0.16) * np.sin(2 * np.pi * f * tc + depth * np.sin(2 * np.pi * f * 1.41 * tc))
    return np.where(t >= 0, v, 0.0)


def _square(t, f):
    """带限方波(奇次谐波叠加),红白机那种芯片音。"""
    v, k = np.zeros_like(t), 1.0
    while f * k < RATE / 2:
        v += np.sin(2 * np.pi * f * k * t) / k
        k += 2
    return v * 4 / np.pi


def _coin(t, first, second, hold):
    """超级玛丽金币:先短促一下,接着拖长渐弱。"""
    tc = np.clip(t, 0, None)
    a = 0.9 * np.minimum(1, tc / 0.002) * _square(tc, first)
    s = tc - hold
    b = np.minimum(1, np.clip(s, 0, None) / 0.002) * np.exp(-np.clip(s, 0, None) / 0.18) * _square(tc, second)
    return np.where(t < 0, 0.0, np.where(tc < hold, a, b))


def _chime(t, f):
    tc = np.clip(t, 0, None)
    return np.where(t >= 0, np.minimum(1, tc / 0.006) * np.exp(-tc * 9) * np.sin(2 * np.pi * f * tc), 0.0)


def _voice(style, start):
    """返回 (时长, 波形函数)。"""
    if style == "marimba":
        a, b = (G5, C6) if start else (C6, G5)
        return 0.32, lambda t: _marimba(t, a) + 0.8 * _marimba(t - 0.07, b)
    if style == "bubble":
        return 0.20, (lambda t: _bubble(t, 500, 1000)) if start else (lambda t: _bubble(t, 900, 450))
    if style == "chime":
        a, b = (660.0, 990.0) if start else (880.0, 587.33)
        return (0.30 if start else 0.27), lambda t: _chime(t, a) + 0.8 * _chime(t - 0.055, b)
    if style == "coin":
        # 开始是金币原调 B5→E6;结束反过来 E6→B5,短一点
        return (0.55, lambda t: _coin(t, B5, E6, 0.08)) if start else (0.40, lambda t: _coin(t, E6, B5, 0.07))
    return 0.40, lambda t: _bell(t, E6 if start else B5)


_cache = {}


def cue(style, start):
    """返回 float32 波形(峰值 0.7,各音色响度一致)。"""
    key = (style, start)
    if key not in _cache:
        duration, wave = _voice(style, start)
        t = np.arange(int(RATE * (duration + LEAD))) / RATE - LEAD
        v = wave(t) * np.clip((duration - t) / 0.03, 0, 1)
        peak = np.abs(v).max()
        if peak > 1e-9:
            v = v * 0.7 / peak
        _cache[key] = v.astype(np.float32)
    return _cache[key]


def playback_gain(peak):
    """历史录音回放增强:轻声录音最多放大 8 倍(18dB),放大后峰值不超过 0.89;静音不放大底噪。"""
    if peak <= 0.0001:
        return 1.0
    return max(1.0, min(8.0, 0.89 / peak))
