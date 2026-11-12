# OneMore · macOS

Swift + 系统原生界面，菜单栏常驻。空闲时不占用麦克风。录音由配置的云端服务识别，数据流向、保存和删除方式见 [数据与隐私说明](../PRIVACY.md)。

## 使用

- 默认 **右 Option**：短按开始、再按一次结束；长按则松开提交。录音时 Esc 取消。
- 首次启动有三步引导：给权限 → 填 API Key（可“测一下”）→ 在框里试一次。
- 菜单栏图标点开只有：当前状态与麦克风／服务一行、麦克风和识别服务切换、提示音与鼠标长按开关、历史记录、设置、退出。缺权限时顶部多一条提醒。
- 个人词典：设置里新增一页,把常用人名、专有名词、英文短语加进去（可一次粘贴多个）,识别时优先用这些写法。
  - 快捷键添加：在任何地方选中文字按 ⌃⌥D（可改）,直接加入词典,胶囊提示“已加入词典”。
  - 从修改里学：语音打完 15 秒内你把某个词改掉了,胶囊问“记住 X？”,⌘⏎ 或点一下胶囊记住,4 秒不理会自动消失（同一纠正忽略 2 次后不再问）。可改为“第 2 次自动记住”或关闭。裸回车不拦。
  - 每个词记录来源（手动/快捷键/纠错）、添加时的应用、最近命中时间,鼠标悬停可见;按需加载后续按这些做。
- 开了“去掉末尾句号”后,同一输入框 2 分钟内接着说下一句（中间没按键没点鼠标）,会先补回上一句的标点；英文之间补空格。
- 回填途中单独按回车不会把半截内容发出去,打完后自动补发一次；带修饰键的回车不拦。
- 服务报错改成大白话（地区不支持、额度用完、模型名不对、服务故障等）。
- 设置窗口支持跟随系统、浅色与深色外观，左侧分栏：通用、模型配置、个人词典、麦克风与提示音、历史记录、权限、附带工具；改动立即保存，没有“保存”按钮。快捷键点“更改”后直接按键或组合键。
- 首次在设置中填写百炼或 MiMo 的 API Key。百炼默认模型 `qwen3.5-omni-flash`；默认提示词按口语整理为通顺书面表达(非逐字转写),可在设置中改。原 Python 版配置会迁移识别服务、Key 和模型,不改动原历史。
- 基础权限为麦克风、辅助功能、输入监控；屏幕录制仅在使用窗口截图时需要，权限页也可查看。
- 等悬浮条从“准备麦克风”变成“录音中”再说话。蓝牙耳机首次打开麦克风可能稍慢。
- 悬浮胶囊可选跟随窗口、固定底部、跟随光标；显示准备、录音和识别状态，完成后隐藏，出错时显示简短说明。
- 提示音有铃声、木琴、气泡、双音、金币五种音色,开始偏高、结束偏低,可在设置中切换、关闭、调整音量和试听。麦克风一通即响,响了就可以说话。
- 麦克风默认“自动”：有线/USB 麦克风优先,其次 Mac 内置,最后才用蓝牙耳机。设置中手动选择的麦克风优先,未连接时再自动选择。
- 蓝牙耳机的麦克风要先切到通话模式,约0.7秒后才能说话,录音期间耳机里听不到提示音,所以排在最后。
- 结束录音后立即释放麦克风,再发送到云端识别。文字输入不经过剪贴板,多行使用 Shift+Return。
- 历史默认保留最近100条，可调整数量、选择永久保留或关闭。输入权限不足时可从历史中复制文字。

数据位于 `~/Library/Application Support/DaiwenVoiceInput/`。API Key 存在本地 `config.json`,不会写入日志。
上传音频通常为16kHz单声道MP3，编码失败回退WAV。单次录音上限10分钟，静音和误触不会上传。
- 在输入框内长按鼠标左键约0.5秒开始录音,松开提交；录音中点一下右键(不会弹菜单),松开左键后自动回车发送。可在设置中关闭。

## 在 Claude Code 等 Electron 应用里回填

这类应用的输入框偶尔会把最后一批字丢掉。回填完成后程序会把输入框内容读回来和打进去的对一下末尾,缺了就补打,确认齐了才放行回车。日志里的“回填校验”只记字数,不记文字。

## 本地开发构建（无需付费签名证书）

需要 macOS 13+、Xcode Command Line Tools（Swift 编译器和 SDK）、与本机架构匹配的 LAME 动态库。安装工具链后，Homebrew 用户可用 `brew install lame` 安装 LAME；已有其他来源的库也可通过环境变量指定。

```sh
./macos/build-dev.command
# 自定义库路径：
VOICE_INPUT_LAME_LIBRARY=/你的路径/libmp3lame.0.dylib ./macos/build-dev.command
```

产物位于 `macos/.build.noindex/OneMore Dev.app`。脚本使用明确的本地临时签名，不查询维护者证书，不安装到 Applications、不创建自启项、不申请系统权限，也不进行公证。默认运行不使用麦克风或网络的核心自检。

开发应用使用独立标识 `com.daiwen.voice-input.development` 和独立数据目录 `~/Library/Application Support/OneMoreDevelopment/`，不会读取正式版 Key、词典和历史。需要界面调试时可手动打开产物，按需使用测试数据和自己的 Key。不要同时运行开发版与正式版，避免快捷键竞争；开发版禁止修改登录自启，避免覆盖正式版设置；也不要将其当正式安装包分发。临时签名重建后的系统权限可能需要重新处理。

脚本按本机架构构建并检查 LAME 架构；当前维护者只在 Apple 芯片机器验证，Intel 构建及另一套干净环境仍待验证。

## 正式构建与安装

正式流程还需要可用的 Developer ID Application 签名证书：

```sh
./macos/install.command
```

`install.command` 构建、验证后替换 `/Applications/OneMore.app`。只构建使用 `./macos/build.command`，产物位于 `.build.noindex/`。正式构建前必须通过 `VOICE_INPUT_CODESIGN_IDENTITY` 指定自己的证书身份（可用 security find-identity -v -p codesigning 查看）。证书不可用时明确失败，不自动退回本地临时签名。保留正式版 bundle ID 与数据路径以兼容既有安装。

## 分发给别人

```sh
./macos/release.command
```

产物是 `macos/dist/OneMore-<版本>.dmg`,已签名并通过 Apple 公证,别人下载后直接双击就能装。dmg 包含 App、Applications 快捷方式、安装说明和数据与隐私说明;API Key、词典、历史都存在 `~/Library/Application Support/DaiwenVoiceInput/`,脚本会检查 App 包里没有任何 json、日志、录音或疑似密钥,有就停止。版本号改 `Info.plist` 里的 `CFBundleShortVersionString`。

第一次用之前要把公证凭证存进钥匙串(只做一次):在 https://account.apple.com 生成一个 App 专用密码,然后执行 `xcrun notarytool store-credentials voice-input --apple-id <Apple ID 邮箱> --team-id <你的 Apple Team ID>`,按提示粘贴密码。没有凭证脚本会停下并打印这段说明。

`VOICE_INPUT_SKIP_NOTARIZE=1` 可以跳过公证只看 dmg,文件名会带"未公证",别发给别人。目前只编 Apple 芯片版本,Intel Mac 装不上。
证书缺失会停止构建,不会退回临时签名。每次构建验证签名并运行不使用麦克风或网络的核心自检。

安装位置保持为 `/Applications/OneMore.app`。从旧的临时签名首次迁移到 Developer ID 时,系统可能需要重新授权一次；后续保持同一签名身份、应用标识和安装位置。

```sh
macos/.build.noindex/OneMore.app/Contents/MacOS/VoiceInput --self-test
```

实际热键需要真实按键验证,不能以自检替代。麦克风、云端转写与自动输入也分别验证。

界面检查不依赖屏幕录制权限：`--settings-preview` / `--onboarding-preview` / `--overlay-preview` 加 `--snapshot-dir <目录>`,程序会把各页面渲染成 PNG 后退出（需先退出正在运行的实例）。整窗渲染里可编辑文本框偶尔显示错字,是渲染方式的问题,单独渲染该控件正常。原生液态玻璃(NSGlassEffectView)渲染不进自截图,带 `--snapshot-dir` 时会退回自绘玻璃,只用于检查排版。

- OneMore 品牌已同步 Windows：共用淡彩 OM 图标与无字体依赖的矢量字标；设置侧栏和首次引导展示品牌及「又一个语音输入法」副标题。应用、Dock、菜单提示和 dmg 使用 OneMore；保留原 bundle ID、可执行名、数据目录及自启标识。install.command 自动迁移旧「语音输入.app」安装与自启路径。
