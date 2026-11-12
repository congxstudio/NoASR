# 团队内部试用

此仓库是从当前可用源码整理出的干净快照，不带旧Git历史、用户数据、设计原型、研究草稿或“发送抓取”功能。仓库保持私有。团队使用自己的API Key，先在无敏感内容的测试输入框中试用。

## 本次审查与处理

- 移除Windows高清训练通道、FLAC副本和训练文字索引；旧训练目录在用户确认清空历史时兼容清理，失败会提示。
- Windows加入UIA密码属性保护：鼠标长按的父元素/光标兜底不能绕过已识别密码框；键盘触发、目标回填和文本读取也做检测。该保护依赖应用正确提供UIA属性，不能保证识别所有自定义密码控件。Windows完整实机验证仍待进行。
- 明确云端请求包含录音、提示词、词典、可选窗口标题及截图，见PRIVACY.md。默认提示词不再带个人健康描述。
- Mac开发构建采用显式临时签名，隔离正式版数据和登录启动；正式构建要求维护者显式提供自己的Developer ID，不携带个人证书身份或公证Team ID。
- 16项Windows存储/密码框逻辑测试通过。测试不打开设备、不执行实际按键、不调用云端服务。
- Mac开发构建及核心自检通过；正式签名构建在维护者本机验证。它们不是全平台端到端测试。

## 同事如何开始

### macOS

1. 安装Xcode Command Line Tools、匹配本机架构的LAME库（Homebrew可用 `brew install lame`）。
2. 在项目根目录执行 `./macos/build-dev.command`。
3. 手动打开 `macos/.build.noindex/OneMore Dev.app`；与正式版不要同时运行，以免抢快捷键。
4. 按系统引导完成所需权限，填写自己的Key并测试连接。开发版数据在OneMoreDevelopment目录，第一次不会读正式版Key。
5. 先测试短按/长按、取消、回填中切换应用、清空临时历史，再试日常使用。录屏权限只在使用截图时需要。

其他同事不应拿维护者的证书或私钥来构建。需要便于安装的签名、公证dmg时由维护者按release.command制作；当前仓库暂不附带安装包。

### Windows

1. 使用Python 3.12，在windows目录建立虚拟环境并安装requirements.txt，然后运行main.pyw。详见windows/README.md。
2. 使用自己的Key，先在测试输入框中验证热键、录音与回填；管理员窗口要验证权限匹配。
3. 使用临时素材验证历史清空、旧训练目录清理、密码框拒绝触发，以及输入过程中主动切换窗口的保护。
4. 逻辑回归：`python -m unittest discover -s windows/tests -v`。逻辑通过不代表Windows音频、UIA和热键在实机都已通过。

Windows依赖尚未形成经干净安装验证的锁定文件；首次安装有问题请反馈Python版本、包版本和简短错误，不附带Key或私人内容。

## 反馈与后续事项

反馈记录操作步骤、系统/应用版本、预期与实际结果；如需截图或日志，先删除私人内容，不上传Key、录音、词典或完整用户历史。

团队试用前后的重点：Windows完整桌面验证、Mac另一台干净机器/Intel验证、Windows依赖版本锁定、第三方组件声明、对外项目许可证、版本与安装包发布流程。当前不宣称已经具备全部对外开源发布条件。

微软UIA密码属性依据：https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.automationelement.ispasswordproperty
