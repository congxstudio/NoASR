#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./build.command
SOURCE="$PWD/.build.noindex/OneMore.app"
DEST="/Applications/OneMore.app"
LEGACY_APPS=("/Applications/语音输入.app" "$HOME/Applications/语音输入.app" "$HOME/Applications/OneMore.app")
STAGING="/Applications/.OneMore-installing.app"
REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p /Applications
# 构建目录永不作为正式入口注册,避免启动台出现重复应用。
"$REGISTER" -u "$SOURCE" || true
if [[ -e "$STAGING" ]]; then
  mv "$STAGING" "$PWD/.build.noindex/incomplete-$(date +%s).app"
fi
ditto "$SOURCE" "$STAGING"
codesign --verify --deep --strict "$STAGING"
app_pids=$(pgrep -f "^(/Applications/OneMore.app|/Applications/语音输入.app|$HOME/Applications/语音输入.app|$HOME/Applications/OneMore.app)/Contents/MacOS/VoiceInput( |$)" || true)
for app_pid in ${(f)app_pids}; do
  [[ -n "$app_pid" ]] && kill -TERM "$app_pid"
done
if [[ -d "$DEST" ]]; then
  mv "$DEST" "$PWD/.build.noindex/previous-$(date +%s).app"
fi
mv "$STAGING" "$DEST"
for LEGACY in "${LEGACY_APPS[@]}"; do
if [[ -d "$LEGACY" ]]; then
  "$REGISTER" -u "$LEGACY" || true
  mv "$LEGACY" "$PWD/.build.noindex/legacy-$(date +%s)-$RANDOM.app"
fi
done
# 保留登录自启设置，只更新应用路径。
/usr/bin/python3 - "$DEST" <<'PYTHON'
import pathlib, plistlib, sys
path = pathlib.Path.home() / "Library/LaunchAgents/com.daiwen.voice-input.plist"
if path.exists():
    data = plistlib.loads(path.read_bytes())
    args = data.get("ProgramArguments", [])
    data["ProgramArguments"] = [sys.argv[1] if arg.endswith(("/语音输入.app", "/OneMore.app")) else arg for arg in args]
    path.write_bytes(plistlib.dumps(data))
PYTHON
touch "$DEST"
"$REGISTER" -f "$DEST"
open "$DEST"
# 安装成功后清理构建副本，避免系统发现多个同名应用。
for copy in "$PWD/.build.noindex/OneMore.app" "$PWD/.build.noindex/语音输入.app" "$PWD"/.build.noindex/{previous-,legacy-,incomplete-}*.app(N); do
  [[ -d "$copy" ]] || continue
  "$REGISTER" -u "$copy" >/dev/null 2>&1 || true
  rm -rf -- "$copy"
done
printf '\n已安装并打开：%s\n' "$DEST"
