# Windows 桌面版

- Python/PySide6，入口main.pyw，核心engine.py，配置/历史config.py，流式输入streaming_input.py，界面ui.py。
- 本机停止应用时优先从托盘退出；不得批量结束所有pythonw进程。仅在需要时按应用PID停止，避免误关其他工具。
- 用户数据默认在windows目录，历史版本可能使用旧项目根目录；任何迁移或测试不得提交、覆盖或删除用户真实数据。
- 麦克风维持常开并跟随设备变化以降低热键延迟，不改成Mac的按需开麦策略。
- 高清训练功能已移除，禁止恢复额外WASAPI录音通道、训练索引或界面开关。用户确认清空历史时兼容删除旧recordings/training目录，失败要明确报告，保留索引供重试。
- 快捷键统一通过shortcuts.py解析和检查冲突；禁止使用keyboard.add_hotkey(suppress=True)，避免全局修饰键锁住。
- 输入用SendInput Unicode，分批核对目标，用户切换应用或主动操作时停止。日志只记状态与字数，不写转写文字、输入框内容或API Key。
- Windows UIA通过密码属性识别受保护输入；不得通过父元素或文字光标兜底绕过已识别的密码框。无法识别的软件仍需实机验证。
- 逻辑测试：`python -m unittest discover -s windows/tests -v`，仅临时数据，不导入实际设备或注入文字。Windows界面、热键、录音及管理员窗口场景必须在Windows真实桌面验证。
- 外观颜色在ui.PALETTES中统一维护，保持浅色玻璃与深色烟灰的对比度，设置改动即时保存。
