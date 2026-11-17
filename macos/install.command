#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./build.command
SOURCE="$PWD/.build.noindex/NoASR.app"
DEST="/Applications/NoASR.app"
LEGACY_APPS=("/Applications/OneMore.app" "/Applications/语音输入.app" "$HOME/Applications/语音输入.app" "$HOME/Applications/OneMore.app" "$HOME/Applications/NoASR.app")
STAGING="/Applications/.NoASR-installing.app"
REGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p /Applications
# 构建目录永不作为正式入口注册,避免启动台出现重复应用。
"$REGISTER" -u "$SOURCE" || true
if [[ -e "$STAGING" ]]; then
  mv "$STAGING" "$PWD/.build.noindex/incomplete-$(date +%s).app"
fi
ditto "$SOURCE" "$STAGING"
codesign --verify --deep --strict "$STAGING"
app_pids=$(pgrep -f "^(/Applications/NoASR.app|/Applications/OneMore.app|/Applications/语音输入.app|$HOME/Applications/语音输入.app|$HOME/Applications/OneMore.app|$HOME/Applications/NoASR.app)/Contents/MacOS/VoiceInput( |$)" || true)
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
/usr/bin/python3 migrate-brand.py "$DEST"
touch "$DEST"
"$REGISTER" -f "$DEST"
open "$DEST"
# 安装成功后清理构建副本，避免系统发现多个同名应用。
for copy in "$PWD/.build.noindex/NoASR.app" "$PWD/.build.noindex/OneMore.app" "$PWD/.build.noindex/语音输入.app" "$PWD"/.build.noindex/{previous-,legacy-,incomplete-}*.app(N); do
  [[ -d "$copy" ]] || continue
  "$REGISTER" -u "$copy" >/dev/null 2>&1 || true
  rm -rf -- "$copy"
done
printf '\n已安装并打开：%s\n' "$DEST"
