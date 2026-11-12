# 团队协作

- 创建分支并通过Pull Request提交，说明具体问题、改动和验证边界。
- 两端分别验证；UI、热键、麦克风与输入流程需在对应系统真实桌面检查。
- Mac本地构建：`./macos/build-dev.command`；Windows逻辑测试：`python -m unittest discover -s windows/tests -v`。
- 测试仅使用临时数据，不向其他应用注入测试文字，不默认发起付费识别，不操作同事真实配置和素材。
- 不提交API Key、配置、录音、截图、词典、历史或私钥。报告问题时先对日志和截图去除私人内容。
- 改动数据留存、云端请求或权限时同步PRIVACY.md和对应平台说明。
