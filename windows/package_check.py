"""安装包无设备自检；只写调用者指定的临时报告。"""
import importlib
import io
import json
from pathlib import Path


def run(output):
    import config
    import numpy as np
    import soundfile as sf
    from PySide6.QtCore import QLibraryInfo
    from PySide6.QtGui import QImage
    from PySide6.QtSvg import QSvgRenderer

    for name in ("sounddevice", "keyboard", "comtypes.client", "httpx2", "uia", "recognition"):
        importlib.import_module(name)
    import comtypes.client
    comtypes.client.GetModule("UIAutomationCore.dll")
    importlib.import_module("comtypes.gen.UIAutomationClient")
    assets = Path(config.SOURCE_DIR) / "assets"
    assert not QImage(str(assets / "noasr.png")).isNull()
    assert not QImage(config.ICON_PATH).isNull()
    assert QSvgRenderer(str(assets / "noasr-wordmark.svg")).isValid()
    assert Path(QLibraryInfo.path(QLibraryInfo.PluginsPath), "platforms", "qwindows.dll").is_file()
    buf = io.BytesIO()
    sf.write(buf, np.zeros(16000, dtype=np.int16), 16000, format="MP3",
             subtype="MPEG_LAYER_III", compression_level=0.9, bitrate_mode="CONSTANT")
    assert len(buf.getvalue()) > 100
    Path(output).write_text(json.dumps({"ok": True, "version": config.APP_VERSION,
        "data_dir": config.BASE_DIR, "launch": config.launch_command(),
        "checks": ["dependencies", "icons", "svg", "qt-platform", "mp3-encoder"]},
        ensure_ascii=False, indent=2), encoding="utf-8")
