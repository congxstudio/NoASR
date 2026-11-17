#!/bin/zsh
# 打一个可以分给别人的安装包:构建 → 检查包里没有私人数据 → 生成 dmg → 签名 → Apple 公证 → 盖章。
# 产物在 macos/dist/NoASR-<版本>.dmg。公证凭证需先执行一次:
#   xcrun notarytool store-credentials voice-input --apple-id <你的 Apple ID 邮箱> --team-id <你的 Apple Team ID>
# 只想看 dmg 长什么样、不公证:VOICE_INPUT_SKIP_NOTARIZE=1 ./release.command(文件名会带"未公证",不要发给别人)。
set -euo pipefail
cd "$(dirname "$0")"
SIGNING_IDENTITY="${VOICE_INPUT_CODESIGN_IDENTITY:?请设置自己的 Developer ID 证书身份 VOICE_INPUT_CODESIGN_IDENTITY，本地开发请用 build-dev.command}"
NOTARY_PROFILE="${VOICE_INPUT_NOTARY_PROFILE:-voice-input}"
SKIP_NOTARIZE="${VOICE_INPUT_SKIP_NOTARIZE:-0}"

if [[ "$SKIP_NOTARIZE" != "1" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat <<EOF
钥匙串里没有公证凭证"$NOTARY_PROFILE"。先做一次(以后不用再做):
  1. 打开 https://account.apple.com → 登录与安全 → App 专用密码 → 生成一个,名字随意
  2. 在终端执行,按提示粘贴刚生成的密码:
     xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <你的 Apple ID 邮箱> --team-id <你的 Apple Team ID>
然后重新运行本脚本。
EOF
  exit 1
fi

./build.command
APP="$PWD/.build.noindex/NoASR.app"

# 包里绝不能有配置、词库、历史或密钥。这些文件本来就只存在 ~/Library/Application Support/DaiwenVoiceInput,这里再兜一道底。
if find "$APP" \( -name '*.json' -o -name '*.log' -o -name '*.mp3' -o -name '*.wav' \) | /usr/bin/grep -q .; then
  echo '应用包里出现了 json/日志/录音文件,停止打包:'; find "$APP" \( -name '*.json' -o -name '*.log' -o -name '*.mp3' -o -name '*.wav' \)
  exit 1
fi
if /usr/bin/grep -rqE 'sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}' "$APP"; then
  echo '应用包里出现了疑似 API Key 的字符串,停止打包。'
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DIST="$PWD/dist"
STAGING="$DIST/staging"
if [[ "$SKIP_NOTARIZE" == "1" ]]; then DMG="$DIST/NoASR-$VERSION-未公证.dmg"; else DMG="$DIST/NoASR-$VERSION.dmg"; fi
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/NoASR.app"
ln -s /Applications "$STAGING/Applications"
cp ../PRIVACY.md "$STAGING/数据与隐私说明.md"
cp ../LICENSE "$STAGING/LICENSE"
cp ../THIRD_PARTY.md "$STAGING/第三方说明.md"
cat > "$STAGING/安装说明.txt" <<'EOF'
NoASR · 安装说明

要求:Apple 芯片的 Mac(M1 及以后),macOS 13 或更新。

1. 把左边的"NoASR"拖到右边的 Applications 文件夹。
2. 在"应用程序"里打开"NoASR",按引导走完三步:
   - 按引导开启麦克风、辅助功能、输入监控；屏幕录制仅在使用窗口截图时需要
   - 填自己的 API Key(阿里云百炼、小米 MiMo、火山、Gemini 任选一家,去对应网站申请)
   - 试着按一次快捷键说句话
3. 菜单栏会多一个图标,以后从那里改设置。

识别在你配置的云端服务上完成，不是离线识别。
录音、提示词与个人词典会发给当前配置的识别服务；开启应用上下文时还会发送应用名与窗口标题。
窗口截图默认关闭；开启后，支持的模型会收到当次截图。
API Key 作为凭据直接发送给配置的服务地址，请确认地址可信。不经过作者的中转服务器。
历史文字、录音和截图按本机设置保留。关闭历史会清理语音历史及其关联媒体，个人词典和配置独立保存。
云端服务如何保存和使用请求数据，以该服务的政策及你的账户设置为准。
完整说明见安装包内“数据与隐私说明.md”。
EOF

hdiutil create -quiet -volname "NoASR" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  printf '\n已生成(未公证,别人打开会被系统拦住):%s\n' "$DMG"
  exit 0
fi

echo '正在上传 Apple 公证,通常 1～5 分钟…'
# 国内网络上传偶尔连接超时,自动重试 3 次;每次都是新的提交,超时的那次 Apple 那边会自己作废。
SUBMIT=""
for attempt in 1 2 3; do
  SUBMIT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$SUBMIT"
  echo "$SUBMIT" | /usr/bin/grep -q 'status: Accepted' && break
  if echo "$SUBMIT" | /usr/bin/grep -qiE 'timeout|connection'; then echo "第 $attempt 次上传超时,重试…"; continue; fi
  break
done
if ! echo "$SUBMIT" | /usr/bin/grep -q 'status: Accepted'; then
  ID=$(echo "$SUBMIT" | /usr/bin/grep -m1 '  id:' | awk '{print $2}')
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" || true
  echo '公证未通过,上面是 Apple 返回的原因。'
  exit 1
fi
xcrun stapler staple -q "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
printf '\n安装包已生成并通过公证,可以直接发给别人:\n%s\n' "$DMG"
