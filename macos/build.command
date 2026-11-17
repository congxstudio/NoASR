#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
SIGNING_IDENTITY="${VOICE_INPUT_CODESIGN_IDENTITY:?请设置自己的 Developer ID 证书身份 VOICE_INPUT_CODESIGN_IDENTITY，本地开发请用 build-dev.command}"
if ! security find-identity -v -p codesigning | /usr/bin/grep -q "$SIGNING_IDENTITY"; then
  echo '缺少固定的 Developer ID 签名证书。停止构建,不会回退到临时签名。'
  exit 1
fi
APP="$PWD/.build.noindex/NoASR.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" Sources/*.swift -o "$APP/Contents/MacOS/VoiceInput"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/NoASR-wordmark*.pdf "$APP/Contents/Resources/"
cp Assets/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
cp Assets/MenuBarNoASR.png "$APP/Contents/Resources/MenuBarNoASR.png"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Icons"
cp Assets/Icons/*.png "$APP/Contents/Resources/Icons/"
LAME_LIBRARY="${VOICE_INPUT_LAME_LIBRARY:-/opt/homebrew/opt/lame/lib/libmp3lame.0.dylib}"
if [[ ! -f "$LAME_LIBRARY" ]]; then
  echo '缺少 LAME 动态库。请安装 lame,或指定 VOICE_INPUT_LAME_LIBRARY。'
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
rm -f "$APP/Contents/Frameworks/libmp3lame.0.dylib"
cp -L "$LAME_LIBRARY" "$APP/Contents/Frameworks/libmp3lame.0.dylib"
install_name_tool -id '@rpath/libmp3lame.0.dylib' "$APP/Contents/Frameworks/libmp3lame.0.dylib"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/libmp3lame.0.dylib"
cp ThirdParty/LAME-COPYING.txt "$APP/Contents/Resources/LAME-COPYING.txt"
cp ../LICENSE "$APP/Contents/Resources/LICENSE"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP"
if [[ "${VOICE_INPUT_SKIP_TESTS:-0}" != "1" ]]; then
  "$APP/Contents/MacOS/VoiceInput" --self-test
fi
printf '\n应用已生成：%s\n' "$APP"
