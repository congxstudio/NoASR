# 第三方组件与素材

本项目自有代码、文档和随仓库提供的自有素材采用 [MIT 协议](LICENSE)。第三方组件继续遵循各自的许可证，项目的 MIT 协议不替代这些许可。当前为早期源码预览版，完整依赖版本与许可清单仍在整理；分发安装包时需核对实际包含的组件及其声明。

| 项目 | 用途 | 来源与说明 |
| --- | --- | --- |
| LAME | Mac运行时MP3编码，动态库构建时复制 | macos/ThirdParty/README.md与LAME-COPYING.txt包含来源和许可；不把本机库提交到仓库 |
| PySide6、sounddevice、NumPy、keyboard、soundfile、comtypes、httpx2 | Windows界面、设备、输入、音频与网络 | 通过windows/requirements.txt安装；实际Windows版本锁定与完整许可清单待在Windows环境确认 |
| PyInstaller、electron-builder、NSIS | Windows 安装预览包构建 | 打包收集运行时依赖许可元数据；NSIS 向导配置与构建工具来源见 windows/installer/README.md；MIT 文本随包附带，工具及组件按各自上游许可处理 |
| NoASR应用图标、菜单栏符号、导航插图 | 本项目界面素材 | 素材来源已由维护者确认，随仓库提供的自有素材采用 MIT 协议。图标来自已确认的 AI 品牌稿；NoASR 字标和菜单栏符号由已确认稿转换为轮廓，导出不依赖字体。仓库保留旧 OM 素材及其提示词归档 |

设计原型、它的 npm 依赖及相关部署配置未迁入本仓库，不属于本次源码预览。运行时依赖的版本与安全情况需单独核对。
