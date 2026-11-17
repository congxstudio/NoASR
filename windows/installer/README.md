# Windows 安装向导

使用 electron-builder 26.18.0 的 NSIS 普通向导，对齐已由用户确认的 JellyGoGo 安装配置：可选安装位置、默认创建桌面/开始菜单快捷方式、完成后默认启动、卸载保留应用数据。没有单独的 MIT 协议确认页，项目许可仍由 PyInstaller 放入安装包的 `_internal/licenses/LICENSE`。

构建前在此目录执行 `npm ci`，然后回到仓库根目录运行 `windows/build-release.ps1`。`build-installer.cjs` 将已经构建的 PyInstaller 目录交给 NSIS；不会打入 Electron 或 Node 运行时。配置中的 `electronVersion` 仅供 electron-builder 初始化其打包框架，`prepackaged` 跳过 Electron 应用构建。NoASR 没有 Electron 自动更新器，因此不打包它的 elevate helper；安装程序自身的权限选择仍由 NSIS 管理。

`installer.nsh` 只补充两个兼容动作：沿用旧 Inno 预览版的安装位置、通过程序的安装专用入口清理确认属于当前目录的旧卸载记录或自启动项。此入口不会读写应用配置、历史或录音；源代码运行不能执行它。NSIS 升级期间保留已有自启动。

构建工具与模板来源：[electron-builder](https://github.com/electron-userland/electron-builder)、[NSIS](https://nsis.sourceforge.io/)。各工具及组件遵循各自上游许可，项目 MIT 协议不替代第三方许可。没有复制 JellyGoGo 的品牌素材或产品代码。

安装和卸载的实机验收边界见 `windows/README.md`、`windows/PARITY.md`。
