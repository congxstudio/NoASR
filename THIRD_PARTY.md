# 第三方组件与素材

本仓库不将第三方代码与品牌素材统一宣称为同一许可证。当前用于团队内部源码试用，正式对外分发前还需补齐组件版本、依赖许可证清单及安装包核对。

| 项目 | 用途 | 来源与说明 |
| --- | --- | --- |
| LAME | Mac运行时MP3编码，动态库构建时复制 | macos/ThirdParty/README.md与LAME-COPYING.txt包含来源和许可；不把本机库提交到仓库 |
| PySide6、sounddevice、NumPy、keyboard、soundfile、comtypes、httpx2 | Windows界面、设备、输入、音频与网络 | 通过windows/requirements.txt安装；实际Windows版本锁定与完整许可清单待在Windows环境确认 |
| OM应用图标、菜单栏符号、导航插图 | 本项目界面素材 | 既有图标由AI生成；OneMore字标由已确认品牌稿描摹。菜单栏提示词保存在macos/Assets/MenuBarOM-prompt.txt；公开品牌授权范围待维护者确认 |

设计原型、它的npm依赖及相关部署配置未迁入本仓库，因此它们不属于本次团队源码快照。不能据此推断运行时依赖已完成全部安全审计。
