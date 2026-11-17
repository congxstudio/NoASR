"""入口:系统托盘常驻的语音输入法。双击或用 pythonw 运行,无控制台窗口。"""
import copy
import ctypes
import logging
import os
import sys
from logging.handlers import RotatingFileHandler

from PySide6.QtCore import QLibraryInfo, QLockFile, QObject, Qt, QTimer, QTranslator
from PySide6.QtGui import QAction, QActionGroup, QGuiApplication, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

import config
import engine as engine_mod
from engine import Engine
from learn import Learner
from mouse_trigger import MouseTrigger
from system_snip import SystemSnip
import ui
from ui import OnboardingWindow, Overlay, SettingsWindow, hotkey_display, make_icon_pixmap

_log_handler = RotatingFileHandler(
    config.LOG_PATH, maxBytes=config.LOG_MAX_BYTES, backupCount=1, encoding="utf-8")
logging.basicConfig(
    handlers=[_log_handler], level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def make_icon():
    """使用随程序分发的多尺寸图标,不再复用本地旧麦克风图标。"""
    return QIcon(config.ICON_PATH)


class App(QObject):  # 继承 QObject,后台线程发来的信号会自动排队到界面线程处理
    """界面层的总控:持有配置(cfg),设置窗口、托盘菜单改动后调用 changed() 保存并应用。"""

    def __init__(self, app):
        super().__init__()
        self.app = app
        first_run = not os.path.exists(config.CONFIG_PATH)
        self.cfg = config.load_config()
        self._dark = None
        self._set_theme()  # 先定好浅色/深色,后面建的窗口和菜单直接用对的配色
        self.overlay = Overlay()
        self.engine = Engine(copy.deepcopy(self.cfg))
        self.engine.level.connect(self.overlay.push_level)
        self.engine.anchor.connect(self.overlay.set_anchor)
        self.engine.state.connect(self.overlay.set_state)
        self.engine.state.connect(self._on_state)
        self.engine.mic_changed.connect(self._on_mic_changed)
        self.engine.copy_text.connect(self._copy_text)
        self.engine.fast_disabled.connect(self._on_fast_disabled)
        self.engine.result.connect(self._on_result)
        self.engine.dictionary_hits.connect(self._on_dictionary_hits)
        self.state = "idle"
        self.settings = None
        self.onboarding = None

        self.tray = QSystemTrayIcon(make_icon(), app)
        menu = self.tray_menu = QMenu()
        self._style_menu()
        self.status_action = QAction("", menu)
        self.status_action.setEnabled(False)
        menu.addAction(self.status_action)
        self.detail_action = QAction("", menu)
        self.detail_action.setEnabled(False)
        menu.addAction(self.detail_action)
        menu.addSeparator()
        self.mic_menu = menu.addMenu("麦克风")
        self.mic_menu.aboutToShow.connect(self._build_mic_menu)
        self.provider_menu = menu.addMenu("识别服务")
        self.provider_menu.aboutToShow.connect(self._build_provider_menu)
        self.model_menu = menu.addMenu("模型")
        self.model_menu.aboutToShow.connect(self._build_model_menu)
        self.sound_action = QAction("提示音", menu, checkable=True)
        self.sound_action.triggered.connect(lambda v: self._toggle("sound", v))
        menu.addAction(self.sound_action)
        self.mouse_action = QAction("输入框长按鼠标说话", menu, checkable=True)
        self.mouse_action.triggered.connect(lambda v: self._toggle("mouse_longpress", v))
        menu.addAction(self.mouse_action)
        menu.addSeparator()
        menu.addAction("历史记录…", lambda: self.open_settings("history"))
        menu.addAction("设置…", lambda: self.open_settings("general"))
        menu.addSeparator()
        menu.addAction("退出", self.quit)
        menu.aboutToShow.connect(self._refresh_status)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(self._on_tray)
        self.tray.show()
        self._refresh_status()
        self.system_snip = SystemSnip(app, self._snip_error)
        self.system_snip.apply(self.cfg)
        app.aboutToQuit.connect(self.system_snip.stop)

        self._mic_notify = False  # 启动时打开麦克风不提示
        self.engine.start()
        # "跟随系统"时每 2 秒读一次 Windows 的深浅色设置(读注册表,几乎没有开销),变了就当场切换
        self._theme_timer = QTimer(self, interval=2000, timeout=self.apply_appearance)
        self._theme_timer.start()
        self._mic_notify = True
        self.learner = Learner(self)
        self.learner.register_hotkey()
        self.mouse = MouseTrigger(self.engine)
        if self.cfg.get("mouse_longpress"):
            self.mouse.start()
        if not config.active_provider(self.cfg)[0]["api_key"]:
            self.open_onboarding()
        if first_run and self.cfg.get("autostart"):
            QTimer.singleShot(0, self._init_autostart)

    def _snip_error(self, message):
        QTimer.singleShot(0, lambda: self.tray.showMessage(
            "截图快捷键", message, QSystemTrayIcon.MessageIcon.Warning, 5000))

    def _init_autostart(self):
        """新配置默认开自启;真实创建任务,权限不足时按实际状态保存。"""
        if config.autostart_enabled():
            self.changed()
            return
        try:
            config.set_autostart(True)
        except Exception:
            logging.exception("首次启动设置开机自启失败")
            self.cfg["autostart"] = config.autostart_enabled()
            self.tray.showMessage("开机自动启动", "请以管理员身份运行后，在设置中开启开机自启")
        self.changed()

    # ----- 配置 -----
    def changed(self):
        """设置被修改:保存、应用到引擎和鼠标长按、刷新托盘。"""
        try:
            config.save_config(self.cfg)
        except OSError:
            logging.exception("保存设置失败")
        old_hotkey = self.engine.cfg.get("hotkey")
        self.engine.apply_config(copy.deepcopy(self.cfg))
        if old_hotkey != self.cfg["hotkey"] and self.engine._hook is not None:
            self.engine.resume_hotkey()
        on = self.cfg.get("mouse_longpress", False)
        self.mouse.start() if on else self.mouse.stop()
        self.learner.register_hotkey()
        self.system_snip.apply(self.cfg)
        self._refresh_status()

    def save_config(self, dictionary=False):
        """词典学习用:dictionary=True 表示词条变了,要同步给引擎(提示词)并刷新词典页;否则只存盘。"""
        if dictionary:
            self.changed()
            if self.settings:
                self.settings.dictionary.refresh()
            return
        try:
            config.save_config(self.cfg)
        except OSError:
            logging.exception("保存设置失败")

    def _toggle(self, key, value):
        self.cfg[key] = value
        self.changed()
        if self.settings:
            self.settings.load(self.cfg)

    def set_autostart(self, on):
        try:
            config.set_autostart(on)
        except Exception as e:
            QMessageBox.warning(self.settings, "提示", f"设置开机自启失败:\n{e}")
            return False
        self.cfg["autostart"] = on
        self.changed()
        if on:
            self.tray.showMessage(config.APP_NAME, "已设置开机自动启动(登录后约 10 秒,以管理员权限运行)")
        return True

    # ----- 外观 -----
    def _wants_dark(self):
        mode = self.cfg.get("appearance", "system")
        return ui.system_is_dark() if mode == "system" else mode == "dark"

    def _set_theme(self):
        """按设置(跟随系统/浅色/深色)确定配色;返回是否有变化。"""
        dark = self._wants_dark()
        if dark == self._dark:
            return False
        self._dark = dark
        ui.set_theme(dark)
        try:  # 让 Qt 自带的对话框(确认框等)也用同样的深浅色
            QGuiApplication.styleHints().setColorScheme(Qt.ColorScheme.Dark if dark else Qt.ColorScheme.Light)
        except AttributeError:
            pass
        logging.info("外观: %s", "深色" if dark else "浅色")
        return True

    def apply_appearance(self):
        """外观设置改了或系统深浅色变了:切换配色并刷新所有已打开的界面,不用重启。"""
        if not self._set_theme():
            return
        self._style_menu()
        for w in (self.settings, self.onboarding):
            if w is not None:
                w.apply_theme()
        self.overlay.update()

    def _style_menu(self):
        self.tray_menu.setStyleSheet(ui.STYLE + "QMenu { padding: 4px; } QMenu::item { padding: 6px 24px 6px 22px; }")

    # ----- 托盘 -----
    def _refresh_status(self):
        p, meta = config.active_provider(self.cfg)
        hk = hotkey_display(self.cfg["hotkey"])
        header = {"recording": "录音中 · 再按一次结束，Esc 取消",
                  "processing": "识别中…"}.get(self.state, f"就绪 · {hk} 说话")
        self.status_action.setText(header)
        detail = f"{self.engine.mic_name or '系统默认麦克风'} · {meta['name']} · {config.model_title(self.cfg['provider'], p['model'])}"
        self.detail_action.setText(detail)
        self.tray.setToolTip(f"{config.APP_NAME} · {header}\n{detail}")
        self.sound_action.setChecked(self.cfg.get("sound", True))
        self.mouse_action.setChecked(self.cfg.get("mouse_longpress", False))

    def _build_mic_menu(self):
        """每次展开时现查设备,插上的新麦克风马上能看到。"""
        m = self.mic_menu
        m.clear()
        group = QActionGroup(m)
        current = self.cfg["device"]
        for value, text in engine_mod.mic_choices(self.engine, current):
            act = QAction(text, m, checkable=True)
            act.setChecked(value == current)
            act.triggered.connect(lambda _c=False, v=value: self._toggle("device", v))
            group.addAction(act)
            m.addAction(act)
        m.addSeparator()
        using = m.addAction(f"正在使用：{self.engine.mic_name or '无可用麦克风'}")
        using.setEnabled(False)

    def _build_provider_menu(self):
        m = self.provider_menu
        m.clear()
        group = QActionGroup(m)
        for key, meta in config.PROVIDERS.items():
            has_key = bool(self.cfg["providers"][key]["api_key"])
            act = QAction(meta["name"] + ("（推荐）" if key == "volcano" else "")
                          + ("" if has_key else "（未填 Key）"), m, checkable=True)
            act.setChecked(key == self.cfg["provider"])
            act.triggered.connect(lambda _c=False, k=key: self.switch_provider(k))
            group.addAction(act)
            m.addAction(act)

    def _build_model_menu(self):
        m = self.model_menu
        m.clear()
        group = QActionGroup(m)
        key = self.cfg["provider"]
        current = self.cfg["providers"][key]["model"]
        for model, title in config.PROVIDERS[key]["models"].items():
            act = QAction(title, m, checkable=True)
            act.setChecked(model == current)
            act.triggered.connect(lambda _c=False, md=model: self.switch_model(md))
            group.addAction(act)
            m.addAction(act)

    def switch_provider(self, key):
        self.cfg["provider"] = key
        self.changed()
        if self.settings:
            self.settings.load(self.cfg)
        if not config.active_provider(self.cfg)[0]["api_key"]:
            self.tray.showMessage(config.APP_NAME, f"{config.PROVIDERS[key]['name']} 还没有填写 API Key,请在设置中填写")
            self.open_settings("service")

    def switch_model(self, model):
        self.cfg["providers"][self.cfg["provider"]]["model"] = model
        self.changed()
        if self.settings:
            self.settings.load(self.cfg)

    def _on_tray(self, reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
            self.open_settings()

    # ----- 引擎事件 -----
    def _on_state(self, state, text):
        if text and state in ("error", "notice"):
            logging.info("状态 %s %s", state, text)
        self.state = state if state in ("recording", "processing") else "idle"
        self._refresh_status()

    def _on_result(self, _text):
        if self.settings and self.settings.isVisible():
            self.settings.history.refresh()

    def _on_dictionary_hits(self, text):
        if config.mark_hits(self.cfg, text):
            self.save_config()

    def _copy_text(self, text):
        QGuiApplication.clipboard().setText(text)

    def _on_fast_disabled(self):
        self.cfg["volcano_fast"] = False
        if self.settings:
            self.settings.load(self.cfg)

    def _on_mic_changed(self, name):
        self._refresh_status()
        if self.settings and self.settings.isVisible() and self.settings.stack.currentWidget() is self.settings.pages["audio"]:
            self.settings._fill_mics()
        if not self._mic_notify:
            return
        self.tray.showMessage(config.APP_NAME, f"麦克风已切换为:{name}" if name else "没有可用的麦克风")

    # ----- 窗口 -----
    def open_settings(self, tab=None):
        if self.onboarding and self.onboarding.isVisible():
            self.onboarding.raise_()
            self.onboarding.activateWindow()
            return
        if self.settings is None:
            self.cfg["autostart"] = config.autostart_enabled()  # 以任务计划里的实际状态为准
            self.settings = SettingsWindow(self)
        else:
            self.settings.load(self.cfg)
        if tab:
            self.settings.select(tab)
        self.settings.showNormal()
        self.settings.raise_()
        self.settings.activateWindow()

    def open_onboarding(self):
        if self.onboarding is None:
            self.onboarding = OnboardingWindow(self)
            self.onboarding.finished.connect(self._onboarding_done)
        self.onboarding.show()
        self.onboarding.raise_()
        self.onboarding.activateWindow()

    def _onboarding_done(self):
        geo = self.onboarding.geometry()
        self.onboarding.deleteLater()
        self.onboarding = None
        self.open_settings("general")
        self.settings.move(geo.topLeft())

    def quit(self):
        self.system_snip.stop()
        self.learner.stop()
        self.mouse.stop()
        self.engine.stop()
        self.tray.hide()
        self.app.quit()


def main():
    # 让任务栏/弹窗使用本程序图标,而不是 Python 图标
    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Daiwen.VoiceInput")
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName(config.APP_NAME)
    app.setApplicationDisplayName(config.APP_NAME)
    app.setWindowIcon(make_icon())
    # 输入框右键菜单(撤销、复制、粘贴等)是 Qt 自己画的,加载 Qt 自带的中文翻译
    translator = QTranslator(app)
    if translator.load("qtbase_zh_CN", QLibraryInfo.path(QLibraryInfo.TranslationsPath)):
        app.installTranslator(translator)

    lock = QLockFile(config.BASE_DIR + "/.app.lock")
    if not lock.tryLock(100):
        QMessageBox.information(None, config.APP_NAME, "程序已在运行,请在系统托盘中查看。")
        return 0

    holder = App(app)  # noqa: F841 保持引用
    if "--settings" in sys.argv:
        holder.open_settings()
    if "--onboarding" in sys.argv:
        holder.open_onboarding()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
