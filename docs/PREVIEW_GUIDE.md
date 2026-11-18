# 预览版指南与已知限制

NoASR 当前为采用 [MIT 协议](../LICENSE) 的早期预览版，提供 [macOS Apple 芯片与 Windows x64 安装包](https://github.com/congxstudio/NoASR/releases/tag/v0.1.0-preview.1)，也支持从源码构建。欢迎体验、反馈问题和参与改进。

仓库从可用源码整理而来，不包含旧项目的 Git 历史、用户数据、设计原型、研究草稿或“发送抓取”功能。请使用自己的 API Key，先在无敏感内容的测试输入框中体验。

## 当前实现与验证边界

- 移除Windows高清训练通道、FLAC副本和训练文字索引；旧训练目录在用户确认清空历史时兼容清理，失败会提示。
- Windows加入UIA密码属性保护：鼠标长按的父元素/光标兜底不能绕过已识别密码框；键盘触发、目标回填和文本读取也做检测。该保护依赖应用正确提供UIA属性，不能保证识别所有自定义密码控件。Windows完整实机验证仍待进行。
- 明确云端请求包含录音、提示词、词典、可选窗口标题及截图，见PRIVACY.md。默认提示词不再带个人健康描述。
- Mac开发构建采用显式临时签名，隔离正式版数据和登录启动；正式构建要求维护者显式提供自己的Developer ID，不携带个人证书身份或公证Team ID。
- Windows 配置迁移、存储与密码框保护已提供逻辑回归，源码检查和自动测试见仓库的 GitHub Actions。测试不打开设备、不执行实际按键、不调用云端服务。
- Mac开发构建及核心自检通过；正式签名构建在维护者本机验证。它们不是全平台端到端测试。

## 安装包

- [macOS DMG 安装盘](https://github.com/congxstudio/NoASR/releases/download/v0.1.0-preview.1/NoASR-0.1.0-preview.1.dmg)：macOS 13+、Apple 芯片，已签名并通过 Apple 公证。挂载后拖入 Applications。
- [Windows x64 安装程序](https://github.com/congxstudio/NoASR/releases/download/v0.1.0-preview.1/NoASR-0.1.0-preview.1-windows-x64-setup.exe)：未签名的 NSIS 安装向导。
- 两端通过核心／逻辑自检；本次 Windows 包另通过临时数据目录中的依赖、图标、Qt 插件与 MP3 编码检查。以上不代替真实桌面、录音、热键和自动输入验收。

## 从源码开始

### macOS

1. 安装Xcode Command Line Tools、匹配本机架构的LAME库（Homebrew可用 `brew install lame`）。
2. 在项目根目录执行 `./macos/build-dev.command`。
3. 手动打开 `macos/.build.noindex/NoASR Dev.app`；与正式版不要同时运行，以免抢快捷键。
4. 按系统引导完成所需权限，填写自己的Key并测试连接。开发版数据在OneMoreDevelopment目录，第一次不会读正式版Key。
5. 先测试短按/长按、取消、回填中切换应用、清空临时历史，再试日常使用。录屏权限只在使用截图时需要。

本地体验使用开发构建即可，无需维护者的证书或私钥。需要制作签名、公证的 dmg 时，按 [Mac 分发说明](../macos/README.md#分发给别人) 准备自己的证书和公证凭证；安装包通过 GitHub Releases 分发。

### Windows

1. 建议使用 Python 3.12，在 `windows/` 目录建立虚拟环境并安装 `requirements.txt`，然后运行 `main.pyw`。详见 [Windows 运行说明](../windows/README.md)。
2. 使用自己的Key，先在测试输入框中验证热键、录音与回填；管理员窗口要验证权限匹配。
3. 使用临时素材验证历史清空、旧训练目录清理、密码框拒绝触发，以及输入过程中主动切换窗口的保护。
4. 逻辑回归：`python -m unittest discover -s windows/tests -v`。逻辑通过不代表Windows音频、UIA和热键在实机都已通过。

Windows依赖尚未形成经干净安装验证的锁定文件；首次安装有问题请反馈Python版本、包版本和简短错误，不附带Key或私人内容。

## 反馈与后续事项

一般问题可通过 [GitHub Issues](https://github.com/congxstudio/NoASR/issues) 反馈，记录操作步骤、系统/应用版本、预期与实际结果；如需截图或日志，先删除私人内容，不上传 Key、录音、词典或完整用户历史。涉及敏感信息的安全问题见 [安全反馈](../SECURITY.md)。

后续重点是 Windows 完整桌面验证、Mac 另一台干净机器及 Intel 构建验证、Windows 依赖版本锁定、第三方组件声明，以及版本与安装包发布流程。上述限制不代表所有使用场景都不可用，也不将日常使用或逻辑测试等同于完整端到端验证。

微软UIA密码属性依据：https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement.ispasswordproperty
