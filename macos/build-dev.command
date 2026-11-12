#!/bin/zsh
# 明确选择的本地开发构建，不使用维护者证书、不安装、不公证。
set -euo pipefail
cd "$(dirname "$0")"
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
  DEFAULT_LAME=/opt/homebrew/opt/lame/lib/libmp3lame.0.dylib
elif [[ "$ARCH" == "x86_64" ]]; then
  DEFAULT_LAME=/usr/local/opt/lame/lib/libmp3lame.0.dylib
else
  echo "不支持的本机架构：$ARCH"; exit 1
fi
LAME_LIBRARY="${VOICE_INPUT_LAME_LIBRARY:-$DEFAULT_LAME}"
if [[ ! -f "$LAME_LIBRARY" ]]; then
  echo '缺少 LAME 动态库。先安装 lame，或指定 VOICE_INPUT_LAME_LIBRARY。'; exit 1
fi
if ! lipo -verify_arch "$ARCH" "$LAME_LIBRARY" >/dev/null 2>&1; then
  echo "LAME 动态库不包含本机架构 $ARCH，请使用匹配架构的库。"; exit 1
fi
APP="$PWD/.build.noindex/OneMore Dev.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Icons" "$APP/Contents/Frameworks"
xcrun swiftc -swift-version 5 -Onone -g -target "$ARCH-apple-macosx13.0" Sources/*.swift -o "$APP/Contents/MacOS/VoiceInput"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.daiwen.voice-input.development' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName OneMore Dev' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName OneMore Dev' "$APP/Contents/Info.plist"
for asset in AppIcon.icns AppIcon.png OneMore-wordmark.pdf MenuBarOM.png; do
  cp "Assets/$asset" "$APP/Contents/Resources/$asset"
done
cp Assets/Icons/*.png "$APP/Contents/Resources/Icons/"
cp ThirdParty/LAME-COPYING.txt "$APP/Contents/Resources/LAME-COPYING.txt"
rm -f "$APP/Contents/Frameworks/libmp3lame.0.dylib"
cp -L "$LAME_LIBRARY" "$APP/Contents/Frameworks/libmp3lame.0.dylib"
install_name_tool -id '@rpath/libmp3lame.0.dylib' "$APP/Contents/Frameworks/libmp3lame.0.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libmp3lame.0.dylib"
codesign --force --sign - --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
if [[ "${VOICE_INPUT_SKIP_TESTS:-0}" != "1" ]]; then
  "$APP/Contents/MacOS/VoiceInput" --self-test
fi
printf '\n本地开发应用已生成：%s\n数据目录：~/Library/Application Support/OneMoreDevelopment/\n不会替换正式应用，不用于分发。\n' "$APP"
