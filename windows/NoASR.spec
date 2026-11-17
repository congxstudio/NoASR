from pathlib import Path
import ast
import os
import re
import sys
from PyInstaller.utils.hooks import collect_submodules, copy_metadata
from PyInstaller.utils.win32.versioninfo import VSVersionInfo, FixedFileInfo, StringFileInfo, StringTable, StringStruct, VarFileInfo, VarStruct

base = Path(SPECPATH)
root = base.parent
tree = ast.parse((base / "config.py").read_text(encoding="utf-8"))
app_version = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "APP_VERSION" for t in n.targets))
version_numbers = [int(v) for v in re.findall(r"\d+", app_version)]
numeric_version = tuple((version_numbers + [0, 0, 0, 0])[:4])
version_info = VSVersionInfo(ffi=FixedFileInfo(filevers=numeric_version, prodvers=numeric_version,
    mask=0x3f, flags=0x2 if "-" in app_version else 0, OS=0x40004, fileType=1, subtype=0, date=(0,0)),
    kids=[StringFileInfo([StringTable("040904B0", [StringStruct(k,v) for k,v in {
        "CompanyName":"congxstudio", "FileDescription":"NoASR", "FileVersion":app_version,
        "InternalName":"NoASR", "OriginalFilename":"NoASR.exe", "ProductName":"NoASR",
        "ProductVersion":app_version, "LegalCopyright":"Copyright (c) 2026 congxstudio"}.items()])]),
        VarFileInfo([VarStruct("Translation", [1033,1200])])])
# 构建宿主可能附带其他软件的 ICU/Qt；不能把这些 DLL 错收进安装包。
os.environ["PATH"] = os.pathsep.join([str(Path(sys.executable).parent), sys.base_prefix,
    str(Path(os.environ["SystemRoot"]) / "System32"), os.environ["SystemRoot"]])
asset_names = ("cloud.png", "dictionary.png", "history.png", "keyboard.png", "microphone.png",
               "tools.png", "noasr.png", "noasr-windows.ico", "noasr-wordmark.svg")
datas = [(str(base / "assets" / name), "assets") for name in asset_names]
datas += [(str(root / name), "licenses" if name == "LICENSE" else "docs")
          for name in ("LICENSE", "PRIVACY.md", "THIRD_PARTY.md")]
for package in ("PySide6", "PySide6_Addons", "PySide6_Essentials", "shiboken6", "sounddevice",
                "numpy", "keyboard", "soundfile", "comtypes", "httpx2"):
    datas += copy_metadata(package, recursive=True)
a = Analysis([str(base / "main.pyw")], pathex=[str(base)], datas=datas,
             hiddenimports=collect_submodules("comtypes", filter=lambda name: not name.startswith("comtypes.test")) + ["package_check"],
             excludes=["tkinter", "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets"],
             noarchive=False)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="NoASR", console=os.environ.get("NOASR_CONSOLE_BUILD") == "1",
          icon=str(base / "assets" / "noasr-windows.ico"), version=version_info, upx=False)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="NoASR")
