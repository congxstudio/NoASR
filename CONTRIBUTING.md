# 贡献指南

NoASR 当前为早期源码预览版，欢迎反馈问题和提交改进。自有代码、文档与项目素材采用 [MIT 协议](LICENSE)；提交贡献时请确保有权按该协议提供相关内容，第三方内容需保留原有许可声明。

- 一般问题可在 [GitHub Issues](https://github.com/congxstudio/OneMore/issues) 中说明；涉及敏感信息的安全问题按 [安全反馈](SECURITY.md) 处理。
- 创建分支并通过Pull Request提交，说明具体问题、改动和验证边界。
- 两端分别验证；UI、热键、麦克风与输入流程需在对应系统真实桌面检查。
- Mac本地构建：`./macos/build-dev.command`；Windows逻辑测试：`python -m unittest discover -s windows/tests -v`。
- 测试仅使用临时数据，不向其他应用注入测试文字，不默认发起付费识别，不操作用户真实配置和素材。
- 不提交API Key、配置、录音、截图、词典、历史或私钥。报告问题时先对日志和截图去除私人内容。
- 改动数据留存、云端请求或权限时同步PRIVACY.md和对应平台说明。
