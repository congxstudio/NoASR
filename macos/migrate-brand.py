"""Update this app's existing startup and Dock references after a bundle rename."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse


def main(destination):
    destination = Path(destination).resolve()
    info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.daiwen.voice-input":
        raise ValueError("Unexpected application identity")
    home = Path.home()
    legacy = {str(folder / name) for folder in (Path("/Applications"), home / "Applications")
              for name in ("OneMore.app", "语音输入.app")}
    exported = subprocess.run(["/usr/bin/defaults", "export", "com.apple.dock", "-"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    dock_count = 0
    if exported.returncode == 0:
        dock = plistlib.loads(exported.stdout)
        for tile in dock.get("persistent-apps", []):
            data = tile.get("tile-data", {})
            file_data = data.get("file-data", {})
            path = unquote(urlparse(file_data.get("_CFURLString", "")).path).rstrip("/")
            if path not in legacy:
                continue
            file_data["_CFURLString"] = destination.as_uri() + "/"
            data["file-label"] = "NoASR"
            data.pop("book", None)
            file_data.pop("book", None)
            dock_count += 1
        if dock_count:
            with tempfile.NamedTemporaryFile(suffix=".plist") as staged:
                staged.write(plistlib.dumps(dock)); staged.flush()
                subprocess.run(["/usr/bin/defaults", "import", "com.apple.dock", staged.name], check=True)
            subprocess.run(["/usr/bin/killall", "Dock"], check=False, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
    startup = home / "Library/LaunchAgents/com.daiwen.voice-input.plist"
    startup_changed = False
    if startup.is_file():
        data = plistlib.loads(startup.read_bytes())
        old_args = data.get("ProgramArguments", [])
        args = [str(destination) if arg in legacy else arg for arg in old_args]
        if args != old_args:
            data["ProgramArguments"] = args
            startup.write_bytes(plistlib.dumps(data))
            domain = "gui/" + str(os.getuid())
            subprocess.run(["/bin/launchctl", "bootout", domain, str(startup)], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["/bin/launchctl", "bootstrap", domain, str(startup)], check=True)
            startup_changed = True
    print("NoASR references updated: Dock={}, startup={}".format(dock_count, startup_changed))


if __name__ == "__main__":
    main(sys.argv[1])
