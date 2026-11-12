# macOS 原生版

- Swift/AppKit，核心配置与历史在 Sources/Config.swift；录音/热键/输入在System.swift；界面在UI.swift；应用调度在main.swift。
- 本地开发用 `./macos/build-dev.command`：明确临时签名，产物OneMore Dev.app，独立bundle ID与OneMoreDevelopment数据目录，禁止修改正式版登录启动。
- 正式构建用 `./macos/build.command`，必须显式提供VOICE_INPUT_CODESIGN_IDENTITY。缺证书直接失败，不自动降级签名。安装用install.command，分发用release.command，必须具备公证凭证。
- 正式bundle ID与DaiwenVoiceInput数据目录是兼容标识，不能随品牌随意改名。只在录音期间开启麦克风，结束、取消、失败均释放设备。
- 热键回调不执行设备或网络重活；左右修饰键用事件自身状态判断，不能用全局状态猜。
- 不读取或存储用户发出的聊天内容；团队版不带发送抓取功能。
- 核心自检为产物Contents/MacOS/VoiceInput --self-test，不使用麦克风或网络。桌面、真实热键与识别需要单独验证。
- 录音、截图、配置只按PRIVACY.md说明处理，不修改TCC数据库、不绕过系统授权。
- UI支持深浅色；菜单栏用MenuBarOM.png模板图像。保持已确认的侧栏紧凑品牌区、标题对齐和红绿灯留白。
