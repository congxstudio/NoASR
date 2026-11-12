"""旧版 Windows 桌面快捷方式的兼容入口。新开发请使用 windows/。"""
from pathlib import Path
import runpy
import sys

folder = Path(__file__).resolve().parent / "windows"
sys.path.insert(0, str(folder))
runpy.run_path(str(folder / "main.pyw"), run_name="__main__")
