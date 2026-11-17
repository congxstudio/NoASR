import AppKit
import AVFoundation
import ApplicationServices

enum RecordingGesture {
    static func staysRecording(mode: String, heldSeconds: Double) -> Bool {
        mode == "toggle" || (mode == "both" && heldSeconds < 0.4)
    }
}

final class VoiceApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var settings = Settings.load()
    let recorder = Recorder()
    let monitor = HotkeyMonitor()
    let screenshotTool = ScreenshotTool()
    var screenshotHotkeyError: String?
    var lastShortcutCapture = -Double.infinity
    let mouse = MouseTrigger()
    var contextTask: Task<String, Never>?
    var screenshotJob: ScreenshotJob?
    var inputDestination: InputDestination?
    var comparisonTasks: [String: Task<Void, Never>] = [:]
    let history = HistoryStore(retention: Settings.load().history_limit, enabled: Settings.load().history_enabled)
    let overlay = Overlay()
    var status: NSStatusItem!
    var warningItem: NSMenuItem!
    let statusView = MenuStatusView()
    var microphoneMenu: NSMenu!
    var providerMenu: NSMenu!
    var soundItem: NSMenuItem!
    var mouseItem: NSMenuItem!
    var settingsWindow: SettingsWindow?
    var onboarding: OnboardingWindow?
    var continuation = ContinuationState()
    let dictionaryHotkey = GlobalHotkey(signature: 0x44564443)
    var dictionaryHotkeyError: String?
    /// 纠错学习:回填完成后开一个短窗口,用户改了字就对比。
    var learnWindow: (destination: InputDestination?, written: String, until: Double, typed: Bool)?
    var learnTimer: Timer?
    var pendingCorrection: CorrectionLearner.Correction?
    var askTimer: Timer?
    var askDeadline: Double = 0
    var cmdReturnMonitor: Any?
    var userActivityMonitor: Any?
    var timer: Timer?
    var state = "idle"
    var sessionID: UUID?
    var pressed = Set<CGKeyCode>()
    var combo: [Set<CGKeyCode>] = []
    var held = false
    var latched = false
    var pressTime = 0.0
    var started = Date()
    var pendingEnd = false
    var pendingEnter = false
    var capturedSettings = Settings()
    var context = ""
    var volume: Double = 0
    var lastPermissions = [Bool]()
    let providerTitles = Provider.titles

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppTheme.apply(settings.appearance)
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.daiwen.voice-input").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        Recognition.onFastUnavailable = { [weak self] requestSettings in
            guard let self, self.settings.volcano_fast,
                  self.settings.providers["volcano"]?.api_key == requestSettings.active.api_key,
                  self.settings.providers["volcano"]?.base_url == requestSettings.active.base_url,
                  self.settings.providers["volcano"]?.model == requestSettings.active.model else { return }
            self.settings.volcano_fast = false
            do { try self.settings.save() }
            catch { Paths.log("Fast 降级设置保存失败") }
            self.settingsWindow?.disableFastAfterFallback()
        }
        history.onError = { [weak self] message in self?.showError(message) }
        // 上次异常退出可能遗留未保存历史的处理音频；仅清理专用前缀。
        if let urls = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for url in urls where url.lastPathComponent.hasPrefix("voice-private-") {
                do { try FileManager.default.removeItem(at: url) }
                catch { Paths.log("临时录音清理失败") }
            }
        }
        NSApp.setActivationPolicy(.regular)
        makeEditMenu()
        status = NSStatusBar.system.statusItem(withLength: 26)
        status.button?.image = BrandHeader.menuIcon()
        status.button?.toolTip = "OneMore · 语音输入"
        status.menu = buildMenu()
        recorder.onLevel = { [weak self] value in self?.volume = value }
        monitor.onEvent = { [weak self] event in self?.key(event) }
        combo = (try? HotkeyMonitor.parse(settings.hotkey)) ?? [[61]]
        monitor.start()
        screenshotTool.onTrigger = { [weak self] in
            guard let self, self.state == "idle", self.settings.screenshot_tool_enabled, ProcessInfo.processInfo.systemUptime - self.lastShortcutCapture > 0.5, self.settingsWindow?.isCapturingHotkey != true,
                  self.onboarding?.isCapturingHotkey != true else { return }
            self.pressed.removeAll(); self.held = false
            self.overlay.hide()
            self.screenshotTool.capture(markup: self.settings.screenshot_markup)
        }
        screenshotTool.onComplete = { [weak self] copied in
            guard let self else { return }
            self.pressed.removeAll(); self.held = false
            guard copied, self.state == "idle" else { return }
            self.overlay.show(.screenshotCopied)
        }
        screenshotTool.onError = { [weak self] message in self?.showError(message) }
        screenshotHotkeyError = screenshotTool.configure(settings.screenshot_tool_enabled ? [settings.screenshot_hotkey, settings.screenshot_hotkey_secondary] : [])
        mouse.enabled = settings.mouse_longpress
        mouse.canBegin = { [weak self] in
            guard let self else { return false }
            if CommandLine.arguments.contains("--onboarding-preview"), self.onboarding?.window?.isVisible == true { return false }
            return self.state == "idle" && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid()
        }
        mouse.onBegin = { [weak self] point in
            guard let self else { return false }
            // 鼠标长按时胶囊贴着按下的位置;CGEvent 坐标原点在左上,转成 AppKit 的左下。
            let height = NSScreen.screens.first?.frame.height ?? 0
            self.begin(anchor: CGRect(x: point.x - 1, y: height - point.y - 6, width: 2, height: 12))
            return ["starting","recording"].contains(self.state)
        }
        mouse.onEnd = { [weak self] enter in self?.pendingEnter = enter; self?.finish() }
        mouse.start()
        if settings.sound { Cues.preload(style: settings.sound_style) }
        recorder.prepare(device: settings.device, uid: settings.device_uid)
        dictionaryHotkey.onTrigger = { [weak self] in self?.addSelectionToDictionary() }
        dictionaryHotkeyError = dictionaryHotkey.configure(settings.dictionary_hotkey)
        if let dictionaryHotkeyError { Paths.log("词典快捷键: \(dictionaryHotkeyError)") }
        overlay.onTap = { [weak self] in self?.confirmCorrection() }
        // ⌘⏎ 确认纠错;只在询问胶囊显示期间有效。
        cmdReturnMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.pendingCorrection != nil, event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command] else { return }
            self.confirmCorrection()
        }
        // 真实按键或点击(非程序注入、非热键)后,下一句不再补上一句的标点。
        userActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.marker else { return }
            if event.type == .keyDown, self.combo.contains(where: { $0.contains(CGKeyCode(event.keyCode)) }) { return }
            if event.type == .keyDown, event.modifierFlags.intersection([.shift, .control, .option, .command]) != [] && event.charactersIgnoringModifiers?.isEmpty != false { return }
            self.continuation.invalidate()
            if self.learnWindow != nil { self.learnWindow?.typed = true }
            if self.pendingCorrection != nil, !(event.type == .keyDown && event.modifierFlags.contains(.command) && (event.keyCode == 36 || event.keyCode == 76)) { self.dismissCorrection(ignored: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        Paths.log("原生版启动;空闲麦克风关闭;权限=\(Permission.granted)")
        // 预览模式:--overlay-preview / --settings-preview / --onboarding-preview,加 --snapshot-dir <目录> 时把各个界面渲染成 PNG 后退出,用于不依赖屏幕录制权限的界面检查。
        let snapshotDir = CommandLine.arguments.firstIndex(of: "--snapshot-dir").flatMap { CommandLine.arguments.count > $0 + 1 ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
        func snapshot(_ view: NSView?, _ name: String) {
            guard let snapshotDir, let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: snapshotDir.appendingPathComponent("\(name).png"))
        }
        if CommandLine.arguments.contains("--overlay-demo") {
            // 只展示UI，不开启麦克风、不调用模型、不向其他窗口输入文字。
            let demo: [(Double, OverlayState)] = [(0, .preparing), (2, .recording(level: 0.68, seconds: 0)), (12, .processing), (16, .done), (18, .error("没有听清"))]
            for (delay, state) in demo {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.state == "idle" else { return }
                    self.overlay.show(state)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--overlay-preview") {
            let states: [(String, OverlayState)] = [("preparing", .preparing), ("recording", .recording(level: 0.68, seconds: 8)), ("processing", .processing), ("done", .done), ("error", .error("没有听清,请在麦克风就绪后说话"))]
            for (index, item) in states.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.6) { self.overlay.show(item.1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.6 + 0.3) { snapshot(self.overlay.panel.contentView, "overlay-\(item.0)") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(states.count) * 1.6 + 1) { self.overlay.hide(); NSApp.terminate(nil) }
            return
        }
        if CommandLine.arguments.contains("--onboarding-preview") {
            openOnboarding()
            if snapshotDir != nil {
                for step in 1...3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.8) { self.onboarding?.preview(step: step); snapshot(self.onboarding?.window?.contentView, "onboarding-\(step)") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { NSApp.terminate(nil) }
            }
            return
        }
        if let flag = ["--settings-preview": SettingsWindow.Tab.general, "--ui-preview": .permissions, "--history-preview": .history].first(where: { CommandLine.arguments.contains($0.key) }) {
            openSettings(flag.value)
            if snapshotDir != nil {
                for tab in SettingsWindow.Tab.allCases {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(tab.rawValue + 1) * 0.8) { self.settingsWindow?.select(tab); snapshot(self.settingsWindow?.window?.contentView, "settings-\(tab.rawValue)-\(tab.title)") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { NSApp.terminate(nil) }
            }
            return
        }
        // 仅正式版首次正常启动创建自启项；预览和自动检查不修改系统设置。
        if !Paths.isDevelopment, !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }),
           !FileManager.default.fileExists(atPath: Paths.config.path) {
            if settings.autostart && !Startup.enabled {
                do { try Startup.set(true) }
                catch { Paths.log("首次启动设置登录自启失败"); showError("登录自启未开启，可在设置中重试") }
            }
            settings.autostart = Startup.enabled
            do { try settings.save() }
            catch { Paths.log("首次启动配置保存失败") }
        }
        if !Permission.allGranted || settings.active.api_key.isEmpty { openOnboarding() }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Paths.log("原生应用启动检查通过"); NSApp.terminate(nil) }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if settingsWindow == nil && onboarding == nil &&
            !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            openSettings(.general)
        }
    }
    func makeEditMenu() {
        let menu = NSMenu(); let application = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 OneMore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; menu.addItem(application)
        let edit = NSMenuItem(); let actions = NSMenu(title: "编辑")
        actions.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        actions.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        actions.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        actions.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = actions; menu.addItem(edit); NSApp.mainMenu = menu
    }
    /// 菜单只做两件事:看当前状态、一键切换常用项。缺权限时顶部多一条提醒。
    func buildMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        warningItem = NSMenuItem(title: "", action: #selector(openPermissions), keyEquivalent: ""); warningItem.target = self
        warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "缺权限")
        menu.addItem(warningItem)
        // 状态块用自定义视图:不可点、不高亮,也不会被画成灰色。
        let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: ""); statusItem.view = statusView
        menu.addItem(statusItem); menu.addItem(.separator())
        let microphone = NSMenuItem(title: "麦克风", action: nil, keyEquivalent: "")
        microphoneMenu = NSMenu(); microphoneMenu.delegate = self; microphone.submenu = microphoneMenu; menu.addItem(microphone)
        let provider = NSMenuItem(title: "识别服务", action: nil, keyEquivalent: "")
        providerMenu = NSMenu(); provider.submenu = providerMenu; menu.addItem(provider)
        for key in Provider.order {
            let item = NSMenuItem(title: providerTitles[key]! + (key == "volcano" ? "（推荐）" : ""), action: #selector(chooseProvider(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key; providerMenu.addItem(item)
        }
        soundItem = NSMenuItem(title: "提示音", action: #selector(toggleSound), keyEquivalent: ""); soundItem.target = self; menu.addItem(soundItem)
        mouseItem = NSMenuItem(title: "输入框长按鼠标说话", action: #selector(toggleMouse), keyEquivalent: ""); mouseItem.target = self; menu.addItem(mouseItem)
        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "历史记录…", action: #selector(openHistory), keyEquivalent: ""); historyItem.target = self; menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsMenu), keyEquivalent: ","); settingsItem.target = self; menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        updateMenu()
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === microphoneMenu { rebuildMicrophoneMenu() } else { updateMenu() }
    }
    func rebuildMicrophoneMenu() {
        microphoneMenu.removeAllItems()
        let devices = Microphone.list()
        let auto = Microphone.preferred(devices, defaultID: Microphone.defaultID())
        let manual = !settings.device_uid.isEmpty || !settings.device.isEmpty
        let autoItem = NSMenuItem(title: "自动（\(auto?.name ?? "系统默认")）", action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
        autoItem.target = self; autoItem.state = manual ? .off : .on; microphoneMenu.addItem(autoItem)
        microphoneMenu.addItem(.separator())
        for mic in devices {
            let kind = ["有线", "内建", "蓝牙"][safe: mic.rank ?? 3] ?? "其他"
            let item = NSMenuItem(title: "\(mic.name)  ·  \(kind)", action: #selector(chooseMicrophone(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mic.uid
            item.state = (settings.device_uid.isEmpty ? mic.name == settings.device && manual : mic.uid == settings.device_uid) ? .on : .off
            microphoneMenu.addItem(item)
        }
    }
    @objc func chooseMicrophone(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String, let mic = Microphone.list().first(where: { $0.uid == uid }) {
            settings.device = mic.name; settings.device_uid = mic.uid
        } else { settings.device = ""; settings.device_uid = "" }
        saveFromMenu()
    }
    @objc func chooseProvider(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        settings.provider = key; saveFromMenu()
        if settings.active.api_key.isEmpty { openSettings(.service) }
    }
    @objc func toggleSound() { settings.sound.toggle(); saveFromMenu() }
    @objc func toggleMouse() { settings.mouse_longpress.toggle(); saveFromMenu() }
    func saveFromMenu() {
        do { try settings.save() } catch { Paths.log("菜单改设置保存失败") }
        apply(settings); settingsWindow?.load(settings)
    }
    /// 设置变化后的统一入口:热键、鼠标开关、提示音预加载、菜单。
    func apply(_ value: Settings) {
        AppTheme.apply(value.appearance)
        if value.screenshot_tool_enabled != settings.screenshot_tool_enabled || value.screenshot_hotkey != settings.screenshot_hotkey || value.screenshot_hotkey_secondary != settings.screenshot_hotkey_secondary || screenshotHotkeyError != nil { screenshotHotkeyError = screenshotTool.configure(value.screenshot_tool_enabled ? [value.screenshot_hotkey, value.screenshot_hotkey_secondary] : []) }
        if value.dictionary_hotkey != settings.dictionary_hotkey || dictionaryHotkeyError != nil { dictionaryHotkeyError = dictionaryHotkey.configure(value.dictionary_hotkey); settingsWindow?.setDictionaryHotkeyError(dictionaryHotkeyError) }
        settings = value
        settingsWindow?.setScreenshotHotkeyError(screenshotHotkeyError)
        if value.dictionary_hotkey != settings.dictionary_hotkey || dictionaryHotkeyError != nil {
            dictionaryHotkeyError = dictionaryHotkey.configure(value.dictionary_hotkey)
            settingsWindow?.setDictionaryHotkeyError(dictionaryHotkeyError)
        }
        mouse.enabled = value.mouse_longpress
        combo = (try? HotkeyMonitor.parse(value.hotkey)) ?? [[61]]
        pressed.removeAll(); held = false
        if value.sound { Cues.preload(style: value.sound_style) }
        recorder.prepare(device: value.device, uid: value.device_uid)
        updateMenu()
    }
    func key(_ event: KeyEvent) {
        if screenshotTool.isRunning { pressed.removeAll(); held = false; return }
        // 使用本次事件的修饰键位校正状态，避免系统快捷键吞掉 keyUp 后残留。
        for code in HotkeyMonitor.modifierFlags.keys {
            if HotkeyMonitor.modifierDown(code: code, flags: event.flags) { pressed.insert(code) }
            else { pressed.remove(code) }
        }
        // 设置窗口开着也照常响应热键(历史记录也在这个窗口里);只有点了“录入”等待按键时才把按键交给它。
        if let window = settingsWindow, window.window?.isVisible == true, window.isCapturingHotkey {
            lastShortcutCapture = ProcessInfo.processInfo.systemUptime
            window.keyCaptured(event.code, down: event.down)
            return
        }
        if onboarding?.isCapturingHotkey == true { return }
        if CommandLine.arguments.contains("--onboarding-preview"), onboarding?.window?.isVisible == true { return }
        if mouse.recording && event.code != 53 { return }
        let inCombo = combo.contains { $0.contains(event.code) }
        if event.down {
            pressed.insert(event.code)
            if event.code == 53 && ["starting","recording"].contains(state) { cancel(); return }
            if !inCombo { if held { cancel() }; return }
            guard !held, combo.allSatisfy({ !$0.isDisjoint(with: pressed) }),
                  pressed.filter({ HotkeyMonitor.modifierFlags[$0] != nil }).allSatisfy({ code in combo.contains { $0.contains(code) } }) else { return }
            held = true; pressTime = event.time
            Paths.log("录音热键按下")
            if latched && ["starting","recording"].contains(state) { finish() }
            else if state == "idle" { begin() }
        } else {
            pressed.remove(event.code)
            guard inCombo && held else { return }
            held = false
            Paths.log("录音热键松开,按住 \(String(format: "%.2f", event.time - pressTime)) 秒")
            guard ["starting","recording"].contains(state), !latched else { return }
            if RecordingGesture.staysRecording(mode: settings.mode, heldSeconds: event.time - pressTime) { latched = true }
            else { finish() }
        }
    }
    func begin(anchor: CGRect? = nil) {
        guard state == "idle", !screenshotTool.isRunning else { return }
        pendingEnter = false
        guard !settings.active.api_key.isEmpty else { openSettings(.service); showError("请先填写识别服务的 API Key"); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { openPermissions(); return }
        let id = UUID(); sessionID = id
        capturedSettings = settings
        let front = NSWorkspace.shared.frontmostApplication
        inputDestination = InputDestination.capture()
        Paths.log("回填策略: \(inputDestination == nil ? "unavailable" : inputDestination!.usesPaste ? "paste" : "stream")")
        let settings = capturedSettings
        let pid = front?.processIdentifier ?? 0; let name = front?.localizedName ?? ""
        contextTask = Task.detached { settings.app_context ? TextInput.details(pid: pid, name: name) : "" }
        // 在胶囊显示/开麦之前安排并行任务；保留触发时的应用和鼠标屏幕位置。
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        screenshotJob?.cancel()
        screenshotJob = settings.window_screenshot ? ScreenshotJob {
            await WindowScreenshot.capture(pid: pid, pointer: pointer, desktopTop: desktopTop)
        } : nil
        let readyStart = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.sessionID == id else { return }
            RecognitionNetwork.shared.warmup(self.capturedSettings.active)
        }
        latched = false; pendingEnd = false; volume = 0; state = "starting"
        let triggerPoint = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        var positionReady = capturedSettings.overlay_position != "window"
        overlay.awaitingPosition = !positionReady
        overlay.lockPosition(at: triggerPoint, mode: capturedSettings.overlay_position)
        updateMenu()
        if positionReady { overlay.show(.preparing) }
        else {
            let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
            let windowTask = Task.detached(priority: .userInitiated) { FrontWindowLocator.rect(pid: pid, desktopTop: desktopTop) }
            Task { @MainActor in
                let window = await windowTask.value
                guard sessionID == id else { return }
                overlay.lockPosition(at: triggerPoint, mode: "window", window: window)
                positionReady = true
                overlay.awaitingPosition = false
                switch state {
                case "starting": overlay.show(.preparing)
                case "recording": overlay.show(.recording(level: volume, seconds: 0))
                case "processing": overlay.show(.processing)
                default: break
                }
            }
        }
        Task { @MainActor in
            do {
                try await recorder.start(device: capturedSettings.device, uid: capturedSettings.device_uid)
                guard sessionID == id, state == "starting" else { _ = try? await recorder.stop(discard: true); return }
                state = "recording"; started = Date()
                Paths.log("麦克风就绪: \(Int(Date().timeIntervalSince(readyStart)*1000))ms")
                if settings.sound { Cues.playStart(volume: capturedSettings.sound_volume, style: capturedSettings.sound_style) }
                if positionReady { overlay.show(.recording(level: 0, seconds: 0)) }
                updateMenu()
                if pendingEnd { finish() }
            } catch {
                guard sessionID == id else { return }
                sessionID = nil; state = "idle"; updateMenu(); showError(error.localizedDescription)
                screenshotJob?.cancel(); screenshotJob = nil
                Paths.log("打开麦克风失败")
            }
        }
    }
    func finish() {
        guard ["starting","recording"].contains(state) else { return }
        if state == "starting" { pendingEnd = true; return }
        let enter = pendingEnter; pendingEnter = false
        mouse.cancel()
        state = "processing"; latched = false; updateMenu()
        overlay.show(.processing)
        let config = capturedSettings; let contextJob = contextTask; let imageJob = screenshotJob; let released = Date(); let timingOrigin = ProcessInfo.processInfo.systemUptime
        screenshotJob = nil
        let destination = inputDestination
        Task { @MainActor in
            var entry: HistoryEntry?
            var ephemeralFiles: [URL] = []
            defer {
                for url in ephemeralFiles where FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { Paths.log("临时录音清理失败"); showError("临时录音清理失败，请检查磁盘权限") }
                }
            }
            var speedSource: URL?
            defer { if let speedSource { try? FileManager.default.removeItem(at: speedSource) } }
            let input = StreamingInput(destination: destination, timingOrigin: timingOrigin, previousText: history.items.first?.text ?? "")
            defer { imageJob?.cancel(); settingsWindow?.historyPane.busyID = nil; settingsWindow?.historyPane.refresh(history.items) }
            do {
                guard let audio = try await recorder.stop() else { throw VoiceError(message: "没有录到声音") }
                if !config.history_enabled { ephemeralFiles.append(audio.url) }
                if settings.sound { Cues.playStop(volume: config.sound_volume, style: config.sound_style) }
                // 此处麦克风已关闭。静音和极短录音不发送到服务商。
                guard audio.duration >= 0.4, audio.voiced >= 0.3 else {
                    try? FileManager.default.removeItem(at: audio.url)
                    throw VoiceError(message: "没有听清,请在麦克风就绪后说话")
                }
                if config.audio_speed_test && config.history_enabled {
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("voice-speed-source-\(UUID().uuidString).wav")
                    do { try FileManager.default.copyItem(at: audio.url, to: copy); speedSource = copy }
                    catch { Paths.log("加速对比源文件准备失败") }
                }
                let prepared = try await Task.detached(priority: .userInitiated) { try AudioPreparation.prepare(audio.url) }.value
                Paths.log("音频准备: \(prepared.rawBytes)B -> \(prepared.bytes)B, \(prepared.rawSeconds)s -> \(prepared.seconds)s, \(prepared.preparationMS)ms")
                if !config.history_enabled { ephemeralFiles.append(prepared.url) }
                let filename = "\(UUID().uuidString).\(prepared.url.pathExtension)"
                let url = config.history_enabled ? Paths.recordings.appendingPathComponent(filename) : FileManager.default.temporaryDirectory.appendingPathComponent("voice-private-" + filename)
                if !config.history_enabled { ephemeralFiles.append(url) }
                try FileManager.default.moveItem(at: prepared.url, to: url)
                entry = HistoryEntry(text: "",error: "",audio: filename,model: config.active.model)
                let start = Date()
                let app = await contextJob?.value ?? ""
                entry!.context = app; entry!.provider = config.provider
                var screenshot: Data?
                // 几乎没说话时截图只会让模型复述画面里的字,不带。
                let shortVoice = audio.voiced < 1.5
                if shortVoice { imageJob?.cancel(); Paths.log("有声 \(String(format: "%.1f", audio.voiced)) 秒,不带截图") }
                if !shortVoice, let result = await imageJob?.value() {
                    entry!.screenshotNote = result.note
                    if let jpeg = result.jpeg {
                        if Recognition.supportsScreenshot(config) {
                            let imageName = "\(entry!.id).jpg"
                            do {
                                let imageURL = Paths.recordings.appendingPathComponent(imageName)
                                if config.history_enabled {
                                    try jpeg.write(to: imageURL, options: [.atomic])
                                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
                                    entry!.screenshot = imageName; entry!.screenshotSource = result.source
                                }
                                screenshot = jpeg
                            } catch { entry!.screenshotNote = "截图保存失败，本次仅使用录音" }
                        } else { entry!.screenshotNote = "当前模型不支持音频与截图组合，本次仅使用录音" }
                    }
                }
                if config.history_enabled && config.screenshot_dual_test && screenshot != nil {
                    entry!.screenshotComparison = ScreenshotComparison(model: config.active.model, provider: config.provider)
                }
                if config.audio_speed_test && config.history_enabled {
                    entry!.audioSpeedComparison = ScreenshotComparison(speedRate: config.audio_speed_rate, model: config.active.model, provider: config.provider)
                }
                history.add(entry!); settingsWindow?.historyPane.busyID = entry!.id; settingsWindow?.historyPane.refresh(history.items)
                if let comparison = entry!.screenshotComparison {
                    startScreenshotComparison(entryID: entry!.id, comparison: comparison, audio: url, config: config, context: app, timingOrigin: timingOrigin)
                }
                if let comparison = entry!.audioSpeedComparison {
                    startSpeedComparison(entryID: entry!.id, comparison: comparison, source: speedSource, config: config, context: app, screenshot: screenshot, timingOrigin: timingOrigin)
                    speedSource = nil // 对比任务接管临时源文件清理。
                }
                let delivery = input.continuation
                // 接着说:第一段文字到来前先补上一句的标点/空格。
                var prefixPending = config.strip_trailing_punct
                let continuationSnapshot = continuation; let destinationSnapshot = destination
                let result = try await Recognition.transcribeDetailed(audio: url, settings: config, context: app, screenshot: screenshot, timingOrigin: timingOrigin, onText: { part in
                    if prefixPending {
                        prefixPending = false
                        let prefix = continuationSnapshot.prefix(for: destinationSnapshot, nextText: part, now: ProcessInfo.processInfo.systemUptime)
                        if !prefix.isEmpty { Paths.log("接着说: 补回上一句末尾 \(prefix.count) 个字符"); delivery.yield(prefix) }
                    }
                    delivery.yield(part)
                })
                let text = result.text
                entry!.text = text; entry!.statistics = result.statistics
                Paths.log("识别完成,用时 \(String(format: "%.2f", Date().timeIntervalSince(start))) 秒")
                await input.finish(sendReturn: enter, finalText: text)
                if input.failure == nil && !input.echoBlocked && !(enter || input.returnHeld) {
                    continuation.remember(destination: destination, originalText: result.rawText, writtenText: text, now: ProcessInfo.processInfo.systemUptime)
                } else { continuation.invalidate() }
                var dictionary = Dictionary.load(); dictionary.markHits(in: text)
                if input.failure == nil && !input.echoBlocked && input.wroteFirst && settings.dictionary_learn != "off" { openLearnWindow(destination: destination, written: text) }
                if let failure = input.failure { entry!.error = failure }
                Paths.log("流式回填结束: elapsed=\(Int(Date().timeIntervalSince(released)*1000))ms completed=\(input.failure == nil)")
                history.updatePrimary(entry!); settingsWindow?.historyPane.refresh(history.items)
                state = "idle"; sessionID = nil; updateMenu()
                if input.echoBlocked { entry!.error = "与上一条几乎相同,判定为模型复述画面,未输入"; history.updatePrimary(entry!); settingsWindow?.historyPane.refresh(history.items); showError("和上一句一样,没有输入") }
                else if input.copiedForRecovery { overlay.show(.copied(partial: input.wroteFirst)) }
                else if let failure = input.failure { showError(failure) }
                else if result.statistics.fastFallback == true { overlay.show(.fastFallback) }
                else { overlay.hide() }
                recorder.prepare(device: settings.device, uid: settings.device_uid)
            } catch {
                await input.finish(sendReturn: false)
                if var saved = entry {
                    if saved.text.isEmpty { saved.text = input.receivedText }
                    saved.error = error.localizedDescription; if history.items.contains(where: { $0.id == saved.id }) { history.updatePrimary(saved) } else { history.add(saved) }; settingsWindow?.historyPane.refresh(history.items) }
                state = "idle"; sessionID = nil; updateMenu(); showError(error.localizedDescription)
                Paths.log(config.history_enabled ? "录音或识别流程失败,结果可在历史查看" : "录音或识别流程失败,历史记录已关闭")
                recorder.prepare(device: settings.device, uid: settings.device_uid)
            }
        }
    }
    /// 辅助请求只写历史，不改变录音状态、不显示胶囊，也绝不注入输入框。
    func startScreenshotComparison(entryID: String, comparison: ScreenshotComparison, audio: URL, config: Settings, context: String, timingOrigin: Double) {
        comparisonTasks[entryID] = Task { @MainActor [weak self] in
            var completed = comparison
            do {
                let result = try await Recognition.transcribeDetailed(audio: audio, settings: config, context: context, screenshot: nil, timingOrigin: timingOrigin)
                try Task.checkCancellation()
                completed.text = result.text; completed.statistics = result.statistics; completed.status = "complete"
            } catch {
                guard !Task.isCancelled else { return }
                completed.status = "failed"; completed.error = error.localizedDescription
            }
            guard let self else { return }
            self.history.updateComparison(entryID: entryID, comparison: completed)
            self.comparisonTasks.removeValue(forKey: entryID)
            self.settingsWindow?.historyPane.refresh(self.history.items)
        }
    }
    func startSpeedComparison(entryID: String, comparison: ScreenshotComparison, source: URL?, config: Settings, context: String, screenshot: Data?, timingOrigin: Double) {
        let key = entryID + ":speed"
        comparisonTasks[key] = Task { @MainActor [weak self] in
            var completed = comparison
            var preparedURL: URL?
            defer {
                if let source { try? FileManager.default.removeItem(at: source) }
                if let preparedURL { try? FileManager.default.removeItem(at: preparedURL) }
            }
            do {
                guard let source else { throw VoiceError(message: "加速对比源文件准备失败") }
                let preparation = Task.detached(priority: .utility) { try AudioSpeed.prepare(source, rate: config.audio_speed_rate) }
                let prepared = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                preparedURL = prepared.url
                try Task.checkCancellation()
                completed.preparationMS = prepared.preparationMS
                completed.originalSeconds = prepared.rawSeconds; completed.acceleratedSeconds = prepared.seconds
                let result = try await Recognition.transcribeDetailed(audio: prepared.url, settings: config, context: context, screenshot: screenshot, timingOrigin: timingOrigin)
                try Task.checkCancellation()
                completed.text = result.text; completed.statistics = result.statistics; completed.status = "complete"
            } catch {
                guard !Task.isCancelled else { return }
                completed.status = "failed"; completed.error = error.localizedDescription
            }
            guard let self else { return }
            self.history.updateSpeedComparison(entryID: entryID, comparison: completed)
            self.comparisonTasks.removeValue(forKey: key)
            self.settingsWindow?.historyPane.refresh(self.history.items)
        }
    }
    func cancel() {
        guard ["starting","recording"].contains(state) else { return }
        Cues.cancel(); mouse.cancel(); contextTask?.cancel(); screenshotJob?.cancel(); screenshotJob = nil
        sessionID = nil; state = "stopping"; latched = false; pendingEnd = false; pendingEnter = false
        held = false; pressed.removeAll()
        overlay.hide(); updateMenu()
        Task { @MainActor in
            _ = try? await recorder.stop(discard: true)
            state = "idle"; updateMenu()
            Paths.log("录音已取消")
            recorder.prepare(device: settings.device, uid: settings.device_uid)
        }
    }
    func tick() {
        let permissions = Permission.granted
        if permissions != lastPermissions {
            lastPermissions = permissions
            Paths.log("权限变化=\(permissions)")
            if permissions[1] && !monitor.active { monitor.start() }
            if permissions[1] && !mouse.active { mouse.start() }
            updateMenu()
        }
        if state == "recording" {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= 600 { finish(); return }
            overlay.show(.recording(level: volume, seconds: Int(elapsed)))
        }
    }
    func updateMenu() {
        let symbol = ["starting": "waveform", "recording": "waveform", "processing": "mic.fill"][state] ?? "mic"
        status.button?.image = state == "idle" ? BrandHeader.menuIcon() : NSImage(systemSymbolName: symbol, accessibilityDescription: "OneMore")
        let missing = Permission.granted.enumerated().filter { !$0.element }.map { Permission.names[$0.offset] }
        warningItem.isHidden = missing.isEmpty
        warningItem.title = missing.isEmpty ? "" : "\(missing.joined(separator: "、"))未开启 · 去开启"
        let header: String; let color: NSColor
        switch state {
        case "starting", "recording": header = "录音中 · 再按一次结束,Esc 取消"; color = .systemRed
        case "processing": header = "识别中…"; color = .systemBlue
        default: header = "就绪 · \(settings.hotkey) 说话"; color = .systemGreen
        }
        let devices = Microphone.list()
        let chosen = devices.first { settings.device_uid.isEmpty ? (!settings.device.isEmpty && $0.name == settings.device) : $0.uid == settings.device_uid }
            ?? Microphone.preferred(devices, defaultID: Microphone.defaultID())
        let detail = "\(chosen?.name ?? "系统默认麦克风") · \(providerTitles[settings.provider] ?? settings.provider) · \(Provider.modelTitle(settings.active.model))"
        statusView.update(title: header, detail: detail, color: color)
        for item in providerMenu.items { item.state = (item.representedObject as? String) == settings.provider ? .on : .off }
        soundItem.state = settings.sound ? .on : .off
        mouseItem.state = settings.mouse_longpress ? .on : .off
    }
    func showError(_ message: String) {
        overlay.show(.error(message))
    }
    @objc func openSettingsMenu() { openSettings(.general) }
    func openSettings(_ tab: SettingsWindow.Tab) {
        cancel(); held = false; pressed.removeAll()
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(settings: settings, history: history.items)
            settingsWindow?.onChange = { [weak self] value in self?.apply(value) }
            settingsWindow?.onAppearanceChange = { [weak self] value in self?.settings.appearance = value }
            settingsWindow?.setScreenshotHotkeyError(screenshotHotkeyError)
            history.onError = { [weak self] message in self?.showError(message) }
            settingsWindow?.historyPane.onRetentionChange = { [weak self] enabled, limit in
                guard let self else { return }
                guard self.state == "idle" else { throw VoiceError(message: "请等待本次录音处理完成后再修改") }
                let old = self.settings
                var draft = old; draft.history_enabled = enabled; draft.history_limit = limit
                try draft.save()
                do { try self.history.configure(enabled: enabled, retention: limit) }
                catch { try? old.save(); throw VoiceError(message: "清理未完成，请检查磁盘权限或空间后重试。部分文件可能已删除。") }
                self.settings = draft; self.settingsWindow?.load(draft)
                if !enabled {
                    self.comparisonTasks.values.forEach { $0.cancel() }; self.comparisonTasks.removeAll()
                }
                self.settingsWindow?.historyPane.refresh(self.history.items)
            }
            settingsWindow?.historyPane.onRegenerate = { [weak self] id in self?.regenerateHistory(id) }
            settingsWindow?.historyPane.onClear = { [weak self] in
                guard let self else { return }
                try self.history.clear()
                self.comparisonTasks.values.forEach { $0.cancel() }; self.comparisonTasks.removeAll()
                self.settingsWindow?.historyPane.refresh(self.history.items)
            }
        } else { settingsWindow?.load(settings) }
        settingsWindow?.historyPane.refresh(history.items)
        settingsWindow?.select(tab)
        showWindow(settingsWindow!)
        settingsWindow?.window?.makeFirstResponder(nil)
    }
    @objc func openPermissions() { openSettings(.permissions) }
    @objc func openHistory() { openSettings(.history) }
    func openOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindow(settings: settings, previewOnly: CommandLine.arguments.contains("--onboarding-preview"))
            onboarding?.onChange = { [weak self] value in self?.apply(value) }
            onboarding?.onFinish = { [weak self] in
                guard let self else { return }
                let old = self.onboarding
                let frame = old?.window?.frame
                self.openSettings(.general)
                if let frame { self.settingsWindow?.window?.setFrame(frame, display: true) }
                old?.window?.close()
                self.onboarding = nil; self.updateMenu()
            }
        }
        showWindow(onboarding!)
    }
    func regenerateHistory(_ id: String) {
        guard state == "idle", var entry = history.items.first(where: { $0.id == id }) else {
            showError("请等待当前录音或识别结束"); return
        }
        guard entry.screenshotComparison?.status != "running", entry.audioSpeedComparison?.status != "running" else { showError("请等待截图对比完成"); return }
        guard !settings.active.api_key.isEmpty else { openSettings(.service); return }
        let config = settings; let url = history.audioURL(entry)
        let timingOrigin = ProcessInfo.processInfo.systemUptime
        state = "processing"; updateMenu(); settingsWindow?.historyPane.busyID = id; settingsWindow?.historyPane.refresh(history.items)
        Task { @MainActor in
            defer {
                state = "idle"; updateMenu(); settingsWindow?.historyPane.busyID = nil; settingsWindow?.historyPane.refresh(history.items)
            }
            do {
                // 重试复用当时提交的图；当前截图开关不会改变已有历史的输入材料。
                var screenshot: Data?
                if let imageURL = history.screenshotURL(entry) {
                    guard let data = try? Data(contentsOf: imageURL) else { throw VoiceError(message: "原截图文件不存在，无法使用原始上下文重新识别") }
                    screenshot = data
                }
                let result = try await Recognition.transcribeDetailed(audio: url, settings: config, context: entry.context ?? "", screenshot: screenshot, timingOrigin: timingOrigin)
                entry.statistics = result.statistics; entry.statistics?.retried = true
                entry.screenshotComparison = nil; entry.audioSpeedComparison = nil
                entry.text = result.text; entry.error = ""; entry.model = config.active.model; entry.provider = config.provider
            } catch { entry.error = "重新识别失败：" + error.localizedDescription }
            history.update(entry)
        }
    }
    // MARK: 词典快捷键 / 纠错学习
    func frontApp() -> (id: String, name: String) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier ?? "", app?.localizedName ?? "")
    }
    func addSelectionToDictionary() {
        Task { @MainActor in
            let text = await SelectionReader.read().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 200 else { showError("先选中要加的词"); return }
            var dictionary = Dictionary.load()
            let app = frontApp()
            let result = dictionary.add(text, source: "hotkey", app: app.id, appName: app.name)
            dictionary.save(); settingsWindow?.dictionaryPane.reload()
            if result.added.isEmpty { showError(result.duplicates.isEmpty ? "没有可加的词" : "词典里已经有了"); return }
            overlay.lockPosition(at: NSEvent.mouseLocation); overlay.show(.learned(terms: result.added))
            Paths.log("词典: 快捷键加入 \(result.added.count) 个(来源 \(app.name))")
        }
    }
    /// 回填完成后 15 秒内观察:用户有真实按键就读回输入框、做差异。
    func openLearnWindow(destination: InputDestination?, written: String) {
        learnTimer?.invalidate()
        guard destination?.usesPaste != true, written.count >= 2 else { return }
        learnWindow = (destination, written, ProcessInfo.processInfo.systemUptime + 15, false)
        learnTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollLearnWindow() }
    }
    func pollLearnWindow() {
        guard var window = learnWindow else { learnTimer?.invalidate(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now > window.until || state != "idle" { learnWindow = nil; learnTimer?.invalidate(); return }
        guard window.typed, window.destination?.isCurrent() == true else { return }
        // 等用户停下来 1 秒再读,避免读到改到一半的
        window.typed = false; learnWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let window = self.learnWindow, !window.typed, window.destination?.isCurrent() == true,
                  let current = FieldReader.value(of: window.destination?.element),
                  let edited = CorrectionLearner.locate(written: window.written, in: current),
                  let correction = CorrectionLearner.diff(written: window.written, edited: edited) else { return }
            self.learnWindow = nil; self.learnTimer?.invalidate()
            self.offerCorrection(correction)
        }
    }
    func offerCorrection(_ correction: CorrectionLearner.Correction) {
        var dictionary = Dictionary.load()
        guard !dictionary.contains(correction.to) else { return }
        let key = correction.from + "→" + correction.to
        if dictionary.ignored[key, default: 0] >= 2 { return }
        if settings.dictionary_learn == "auto" {
            let seen = dictionary.ignored["seen:" + key, default: 0] + 1
            dictionary.ignored["seen:" + key] = seen; dictionary.save()
            if seen >= 2 { learn(correction); return }
            // 第一次只记录,不打扰
            Paths.log("纠错学习: 首次见到 \(correction.from.count)→\(correction.to.count) 字,先记一笔")
            return
        }
        pendingCorrection = correction
        askDeadline = ProcessInfo.processInfo.systemUptime + 4
        overlay.lockPosition(at: NSEvent.mouseLocation)
        overlay.show(.learnAsk(term: correction.to, progress: 1))
        askTimer?.invalidate()
        askTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let pending = self.pendingCorrection else { return }
            let left = self.askDeadline - ProcessInfo.processInfo.systemUptime
            if left <= 0 { self.dismissCorrection(ignored: true); return }
            self.overlay.show(.learnAsk(term: pending.to, progress: left / 4))
        }
    }
    func confirmCorrection() {
        guard let correction = pendingCorrection else { return }
        pendingCorrection = nil; askTimer?.invalidate()
        learn(correction)
    }
    func dismissCorrection(ignored: Bool) {
        guard let correction = pendingCorrection else { return }
        pendingCorrection = nil; askTimer?.invalidate(); overlay.hide()
        if ignored {
            var dictionary = Dictionary.load()
            dictionary.ignored[correction.from + "→" + correction.to, default: 0] += 1; dictionary.save()
        }
    }
    func learn(_ correction: CorrectionLearner.Correction) {
        var dictionary = Dictionary.load()
        let app = frontApp()
        let result = dictionary.add(correction.to, source: "correction", app: app.id, appName: app.name)
        dictionary.save(); settingsWindow?.dictionaryPane.reload()
        guard !result.added.isEmpty else { overlay.hide(); return }
        overlay.show(.learned(terms: result.added))
        Paths.log("纠错学习: 记住 1 个词(来源 \(app.name))")
    }
    @objc func quitApp() { monitor.stop(); mouse.stop(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { screenshotTool.stop(); screenshotJob?.cancel(); comparisonTasks.values.forEach { $0.cancel() }; Cues.cleanup() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let onboarding { showWindow(onboarding) }
        else if let settingsWindow { showWindow(settingsWindow) }
        else { openSettings(.general) }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

if CommandLine.arguments.contains("--self-test") {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n",stderr); exit(1) }
        print("PASS: \(message)")
    }
    check(HotkeyMonitor.modifierDown(code: 61,flags: 0x80140),"右 Option 按下")
    check(!HotkeyMonitor.modifierDown(code: 61,flags: 0x100),"右 Option 松开")
    check(!HotkeyMonitor.modifierDown(code: 61,flags: 0x80020),"左 Option 按住时右 Option 松开")
    check((try? HotkeyMonitor.parse("right option")) == [[61]],"默认热键")
    check((try? HotkeyMonitor.parse("ctrl+shift+space"))?.count == 3,"组合热键")
    check((try? HotkeyMonitor.parse("invalid key")) == nil,"拒绝无效热键")
    check(Settings().mode == "both","默认同时支持短按和长按")
    do { try SettingsTests.run(); print("PASS: 默认配置与旧配置兼容") }
    catch { fputs("FAIL: 默认配置与旧配置兼容：\(error.localizedDescription)\n", stderr); exit(1) }
    do {
        var g = EchoGuard(previous: "可以理解为，现在给你接上之后，你等同于拥有了多模态整个的API能力，是吗")
        var out = ""
        for part in ["可以理解为", "现在给你接上之后，", "你等同于拥有了多模态的", "整个的 API 的能力，是吗"] { out += g.admit(part) }
        out += g.flush()
        check(g.blocked && out.isEmpty, "复述守卫: 几乎相同的结果整条拦下")
        g = EchoGuard(previous: "可以理解为，现在给你接上之后，你等同于拥有了多模态整个的API能力，是吗")
        out = ""
        for part in ["可以理解为", "明天不开会了，", "大家把材料发我"] { out += g.admit(part) }
        out += g.flush()
        check(!g.blocked && out == "可以理解为明天不开会了，大家把材料发我", "复述守卫: 开头相同但内容不同,攒的字全部放行")
        g = EchoGuard(previous: "好的"); out = g.admit("今天天气不错")
        check(out == "今天天气不错", "复述守卫: 上一条很短时不拦")
    }
    do {
        var d = Dictionary()
        let r = d.add("Claude Code, 王代文、Codex;Claude code\n飞书")
        check(r.added == ["Claude Code", "王代文", "Codex", "飞书"] && r.duplicates == ["Claude code"], "词典: 拆分、保留英文短语、英文不分大小写去重")
        d.remove("Codex"); check(d.terms == ["Claude Code", "王代文", "飞书"], "词典: 删除")
        var c = ContinuationState()
        let dest = InputDestination(pid: 42, element: nil, usesPaste: false)
        c.remember(destination: dest, originalText: "今天开会。", writtenText: "今天开会", now: 100)
        check(c.prefix(for: dest, nextText: "下午三点", now: 160) == "。", "接着说: 2 分钟内同一目标补回句号")
        check(c.prefix(for: dest, nextText: "下午三点", now: 100 + 121) == "", "接着说: 超过 2 分钟不补")
        c.invalidate(); check(c.prefix(for: dest, nextText: "下午", now: 110) == "", "接着说: 中间有按键后不补")
        c.remember(destination: dest, originalText: "see you.", writtenText: "see you", now: 200)
        check(c.prefix(for: dest, nextText: "tomorrow", now: 210) == ". ", "接着说: 英文句号后补空格")
        check(Recognition.plainError(status: 403, body: Data("unsupported_country_region_territory".utf8)).contains("地区"), "报错: 地区限制说成人话")
        check(Recognition.plainError(status: 429, body: Data("insufficient_quota".utf8)).contains("额度"), "报错: 额度用完")
        check(Recognition.plainError(status: 503, body: Data()).contains("故障"), "报错: 服务故障")
    }
    do {
        typealias C = CorrectionLearner
        check(C.diff(written: "我想知道夕晴今天什么时候回去", edited: "我想知道西芹今天什么时候回去") == C.Correction(from: "夕晴", to: "西芹"), "纠错: 中文同音替换")
        check(C.diff(written: "把克劳德的代码发我", edited: "把 Claude 的代码发我") == C.Correction(from: "克劳德", to: "Claude"), "纠错: 中文换英文")
        check(C.diff(written: "用 fastmail 收信", edited: "用 Fastmail 收信") == C.Correction(from: "fastmail", to: "Fastmail"), "纠错: 英文整词扩展")
        check(C.diff(written: "今天开会", edited: "今天开会。") == nil, "纠错: 只加标点不算")
        check(C.diff(written: "今天开会", edited: "明天不开会了大家先把材料发我") == nil, "纠错: 整句重写不算")
        check(C.diff(written: "今天开会讨论方案", edited: "今天讨论方案") == nil, "纠错: 只删字不算")
        check(C.locate(written: "我想知道夕晴今天什么时候回去", in: "之前的内容。我想知道西芹今天什么时候回去 谢谢") == "我想知道西芹今天什么时候回去", "纠错: 在前后有别的文字时定位到改过的那段")
        check(C.locate(written: "我想知道夕晴今天什么时候回去", in: "完全不相关的内容") == nil, "纠错: 找不到就放弃")
        var d = Dictionary(); d.add("西芹", source: "correction", app: "com.tencent.xinWeChat", appName: "微信")
        check(d.items.first?.app == "com.tencent.xinWeChat" && d.items.first?.source == "correction", "词典: 记录来源应用")
        d.markHits(in: "西芹今天回来"); check(d.items.first?.lastHit != nil, "词典: 记命中")
    }
    do {
        typealias V = FillVerifier
        check(InputDestination.hasChromiumFramework(["Sparkle.framework", "Codex Framework.framework"]), "回填校验: Codex 框架启用校验")
        check(["Electron Framework.framework", "Chromium Embedded Framework.framework", "Google Chrome Framework.framework"].allSatisfy { InputDestination.hasChromiumFramework([$0]) }, "回填校验: 原有 Chromium 框架继续识别")
        check(!InputDestination.hasChromiumFramework([]) && !InputDestination.hasChromiumFramework(["Sparkle.framework", "AppKit.framework"]), "回填校验: 普通应用不误启用")
        check(V.missingTail(typed: "今天天气不错我们出去走走", field: "之前的话。今天天气不错我们出去走走") == "", "回填校验: 末尾齐全")
        check(V.missingTail(typed: "今天天气不错我们出去走走", field: "之前的话。今天天气不错我们") == "出去走走", "回填校验: 少最后几个字")
        check(V.missingTail(typed: "we go to the park now", field: "we go to the") == " park now", "回填校验: 英文缺尾巴带空格")
        check(V.missingTail(typed: "第一行\n第二行", field: "第一行\n第二") == "行", "回填校验: 忽略换行表示差异")
        check(V.missingTail(typed: "今天天气不错", field: "完全无关的内容") == nil, "回填校验: 对不上时不判断")
        check(V.missingTail(typed: "", field: "随便") == "", "回填校验: 没打字就算齐")
        let expected = "测试文字全部到齐", incomplete = "已有内容。测试文字全部"
        let missing = V.missingTail(typed: expected, field: incomplete)
        check(missing == "到齐" && V.missingTail(typed: expected, field: incomplete + (missing ?? "")) == "", "回填校验: 补回缺尾后按原全文复查齐全")
    }
    check(Recognition.looksLikeNoSpeech("没有清晰说话内容") && Recognition.looksLikeNoSpeech("（无法识别的语音）") && Recognition.looksLikeNoSpeech("。") && Recognition.looksLikeNoSpeech("空") && Recognition.looksLikeNoSpeech("（空字符串）"),"模型描述“没听清”不当作结果")
    check(!Recognition.looksLikeNoSpeech("是") && !Recognition.looksLikeNoSpeech("我没有收到他的录音文件,你再发一次吧") && !Recognition.looksLikeNoSpeech("今天没有会"),"正常短句和含“没有”的长句不误判")
    check(Settings().active.model == "doubao-seed-2-1-lite-260915" && Settings().prompt.contains("表达助手"),"默认火山模型与表达助手提示词")
    var hold = MouseHoldGesture(); hold.begin(.zero)
    check(!hold.rightClick() && !hold.enter,"未开始录音时右键不拦截")
    hold.active = true
    check(hold.rightClick() && hold.enter,"录音中右键记为自动回车")
    hold.reset(); check(!hold.enter,"结束后清除回车标记")
    check(Cues.validStyle(nil) == "bubble" && Cues.validStyle("无效") == "bubble" && Cues.validStyle("marimba") == "marimba","提示音音色校验")
    for (key, _) in Cues.styles {
        let start = Cues.audio(start: true, style: key), stop = Cues.audio(start: false, style: key)
        check(start.count > 2000 && stop.count > 2000 && (try? AVAudioPlayer(data: start)) != nil && (try? AVAudioPlayer(data: stop)) != nil,"提示音音色可生成并可播放: \(key)")
    }
    let builtIn = Microphone(id: 1, name: "内置", uid: "b", transport: kAudioDeviceTransportTypeBuiltIn)
    let bluetooth = Microphone(id: 2, name: "蓝牙", uid: "t", transport: kAudioDeviceTransportTypeBluetooth)
    let usb = Microphone(id: 3, name: "USB", uid: "u", transport: kAudioDeviceTransportTypeUSB)
    let virtual = Microphone(id: 4, name: "虚拟", uid: "v", transport: kAudioDeviceTransportTypeVirtual)
    check(Microphone.preferred([bluetooth, builtIn, usb], defaultID: 2)?.id == 3, "自动选麦:有线优先")
    check(Microphone.preferred([bluetooth, builtIn], defaultID: 2)?.id == 1, "自动选麦:内置优先于蓝牙")
    check(Microphone.preferred([virtual, bluetooth], defaultID: 4)?.id == 2, "自动选麦:不选虚拟设备,只剩蓝牙时用蓝牙")
    check(Microphone.preferred([virtual], defaultID: 4) == nil, "自动选麦:没有可选设备时交给系统默认")
    do { let converted = try Recorder.checkConversion(); check(converted, "48kHz 双声道转 16kHz 单声道 WAV 与静音检测") }
    catch { fputs("音频转换失败: \(error.localizedDescription)\n",stderr); exit(1) }
    let capsuleSize = NSSize(width: 160, height: 40)
    let testScreen = CGRect(x: -1200, y: -200, width: 1200, height: 800)
    let floatingWindow = CGRect(x: -1000, y: 100, width: 600, height: 400)
    check(OverlayPlacement.origin(size: capsuleSize, frame: testScreen, pointer: nil, window: floatingWindow) == NSPoint(x: -780, y: 4), "跟随窗口优先窗外下方56pt")
    check(OverlayPlacement.origin(size: capsuleSize, frame: testScreen, pointer: nil, window: testScreen) == NSPoint(x: -680, y: -144), "全屏窗口使用底部内侧56pt")
    check(OverlayPlacement.origin(size: capsuleSize, frame: testScreen, pointer: nil) == NSPoint(x: -680, y: -144), "胶囊底部居中支持副屏坐标")
    check(OverlayPlacement.origin(size: capsuleSize, frame: testScreen, pointer: NSPoint(x: -600, y: 300)) == NSPoint(x: -680, y: 204), "胶囊在鼠标下方56pt")
    let cornerPosition = OverlayPlacement.origin(size: capsuleSize, frame: testScreen, pointer: NSPoint(x: -1199, y: -199))
    check(cornerPosition.x == -1192 && cornerPosition.y == -143, "胶囊边缘避让并在底部翻到鼠标上方")
    check(RecordingGesture.staysRecording(mode: "both", heldSeconds: 0.08), "短按0.08秒继续录音,不会当成误触丢弃")
    check(!RecordingGesture.staysRecording(mode: "both", heldSeconds: 1), "长按松开后提交")
    check(RecordingGesture.staysRecording(mode: "toggle", heldSeconds: 1), "单击切换模式松开后继续")
    check(!RecordingGesture.staysRecording(mode: "hold", heldSeconds: 0.1), "按住模式松开后结束")
    check(Settings().providers["bailian_cn"]?.base_url == "https://dashscope.aliyuncs.com/compatible-mode/v1", "百炼北京独立节点")
    var gesture = MouseHoldGesture(); gesture.begin(.zero); gesture.move(CGPoint(x: 7,y: 0))
    check(!gesture.eligible,"拖动选字不启动录音")
    gesture.begin(.zero); gesture.active = true; gesture.move(CGPoint(x: 20,y: 0))
    check(gesture.active && !gesture.moved,"录音后移动鼠标不取消")
    let samples = [Int16](repeating:0,count:16000) + [Int16](repeating:3000,count:16000) + [Int16](repeating:0,count:16000)
    check(AudioPreparation.trimmedRange(samples) == 12000..<36000,"裁首尾静音并保留250ms")
    do {
        let data = try MP3Encoder().encode(samples)
        check(data.count < samples.count * 2 / 5,"MP3 上传体积降低超过60%")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-encode-test.mp3")
        try data.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
        let decoded = try AVAudioFile(forReading:url)
        check(decoded.length > 0,"压缩文件可解码")
        let enhanced = try AudioPlayback.enhanced(url)
        let playback = try AVAudioPlayer(data: enhanced)
        check(playback.duration > 2.9, "增强回放副本可播放且时长完整")
        print("MP3 test: PCM=\(samples.count*2)B MP3=\(data.count)B")
    } catch { fputs("MP3 test failed: \(error)\n",stderr); exit(1) }
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        var entries: [HistoryEntry] = []
        for i in 0..<(HistoryStore.limit + 2) {
            let entry = HistoryEntry(text: "fixture", error: "", audio: "\(i).wav", model: "test")
            entries.append(entry); try Data([0]).write(to: root.appendingPathComponent(entry.audio))
        }
        try JSONEncoder().encode(entries).write(to: file)
        let store = HistoryStore(file: file, recordings: root)
        check(store.items.count == HistoryStore.limit, "启动时旧历史收敛为 \(HistoryStore.limit) 条")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(HistoryStore.limit + 1).wav").path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("0.wav").path), "超限录音清理,保留的不删")
        var changed = store.items[0]; changed.text = "updated"; store.update(changed)
        let reloaded = HistoryStore(file: file, recordings: root)
        check(reloaded.items.count == HistoryStore.limit && reloaded.items[0].text == "updated", "重新生成更新原条目且持久化")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("0.wav").path), "更新识别结果保留录音")
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        try reloaded.clear()
        check(reloaded.items.isEmpty && HistoryStore(file: file, recordings: root).items.isEmpty, "清空历史并持久化")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("0.wav").path) && FileManager.default.fileExists(atPath: unrelated.path), "清空录音且保留无关文件")

    } catch { fputs("History test failed: \(error)\n",stderr); exit(1) }
    check(AudioPlayback.gain(peak:0.1) == 8, "轻声回放增益上限18dB")
    check(AudioPlayback.gain(peak:0.95) == 1, "正常音量录音不强行增益")
    check(AudioPlayback.gain(peak:0) == 1, "静音不放大底噪")
    print("Native core checks passed; no microphone or network used")
    exit(0)
}
if CommandLine.arguments.contains("--microphone-test") {
    let recorder = Recorder()
    Task {
        do {
            let settings = Settings.load()
            recorder.prepare(device: settings.device, uid: settings.device_uid)
            try await Task.sleep(nanoseconds: 300_000_000)
            for round in 1...3 {
                let begin = Date()
                try await recorder.start(device: settings.device, uid: settings.device_uid)
                print("第\(round)轮 按下到收到声音: \(Int(Date().timeIntervalSince(begin) * 1000))ms")
                try await Task.sleep(nanoseconds: 500_000_000)
                _ = try await recorder.stop(discard: true)
                try await Task.sleep(nanoseconds: 300_000_000)
                if let device = recorder.idleDevice { print("空闲时设备是否在采集: \(Recorder.isRunning(device: device))") }
            }
            print("PASS: 真实麦克风开启、采集、关闭并丢弃录音;未上传")
            exit(0)
        } catch { _ = try? await recorder.stop(discard: true); fputs("麦克风测试失败：\(error.localizedDescription)\n",stderr); exit(1) }
    }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--transcribe-test"), CommandLine.arguments.count > index + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task {
        do {
            let text = try await Recognition.transcribe(audio: url, settings: Settings.load(), context: "本地功能测试")
            print("云端识别成功,字符数：\(text.count)")
            exit(0)
        } catch { fputs("云端识别失败：\(error.localizedDescription)\n",stderr); exit(1) }
    }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--benchmark-transcription"), CommandLine.arguments.count > index + 1 {
    let source = URL(fileURLWithPath: CommandLine.arguments[index+1])
    Task {
        do {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-\(UUID().uuidString).wav")
            try FileManager.default.copyItem(at:source,to:copy)
            let prepared = try AudioPreparation.prepare(copy)
            defer { try? FileManager.default.removeItem(at:prepared.url) }
            print("Audio: \(prepared.rawBytes)B -> \(prepared.bytes)B prep=\(prepared.preparationMS)ms")
            // --provider volcano|bailian_cn|mimo|gemini 可指定服务商,便于对比线路;不传则用设置里的当前服务商。
            var settings = Settings.load()
            if let flag = CommandLine.arguments.firstIndex(of: "--provider"), CommandLine.arguments.count > flag + 1, Provider.defaults[CommandLine.arguments[flag+1]] != nil {
                settings.provider = CommandLine.arguments[flag+1]
            }
            print("Provider: \(settings.provider) model=\(Provider.modelTitle(settings.active.model))")
            for (name,url) in [("WAV cold",source),("WAV warm",source),("MP3 warm",prepared.url)] {
                let start = Date()
                let text = try await Recognition.transcribe(audio:url,settings:settings,context:"")
                print("\(name): \(Int(Date().timeIntervalSince(start)*1000))ms chars=\(text.count)")
            }
            exit(0)
        } catch { fputs("Benchmark failed: \(error.localizedDescription)\n",stderr); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--cue-play-test") {
    let loaded = Settings.load(); Cues.preview(volume: loaded.sound_volume, style: loaded.sound_style)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Cues.cleanup(); exit(0) }
    dispatchMain()
}
if CommandLine.arguments.contains("--cue-preview") {
    let folder = URL(fileURLWithPath: "/tmp")
    for (key, _) in Cues.styles {
        try Cues.audio(start: true, style: key).write(to: folder.appendingPathComponent("voice-input-\(key)-start.wav"))
        try Cues.audio(start: false, style: key).write(to: folder.appendingPathComponent("voice-input-\(key)-stop.wav"))
    }
    print("提示音预览已导出")
    exit(0)
}
// 隔离的合成数据验证，不读取真实历史、不启动录音或发送模型请求。
if CommandLine.arguments.contains("--screenshot-self-test") {
    Task {
        do { try await ScreenshotTests.run(); exit(0) }
        catch { fputs("Screenshot tests failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--screenshot-ui-preview") {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let jpeg = try WindowScreenshot.compress(ScreenshotTests.fixture())
    try jpeg.write(to: root.appendingPathComponent("fixture.jpg"))
    let controller = SettingsWindow(settings: Settings(), history: [])
    controller.historyPane.screenshotDirectory = root
    var sample = HistoryEntry(text: Array(repeating: "这是用于检查长文本折叠的示例内容。截图与录音并行处理，历史卡片保留完整文字和原始提交截图。", count: 12).joined(separator: "\n\n"), error: "", audio: "missing-fixture.wav", model: "界面预览 · 合成数据")
    sample.screenshot = "fixture.jpg"; sample.screenshotSource = "window"
    controller.historyPane.refresh([sample, HistoryEntry(text: "短文本保持完整展示。", error: "", audio: "missing-fixture.wav", model: "界面预览")])
    controller.select(.history); controller.showWindow(nil); app.activate(ignoringOtherApps: true)
    if CommandLine.arguments.contains("--capture-preview-window") {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGEvent(source: nil)?.location ?? .zero
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let started = Date()
            let job = ScreenshotJob { await WindowScreenshot.capture(pid: getpid(), pointer: point, desktopTop: top) }
            let result = await job.value()
            print("Preview capture: source=\(result.source ?? "none") bytes=\(result.jpeg?.count ?? 0) timeMS=\(Int(Date().timeIntervalSince(started) * 1000))")
            // 仅验证本预览窗口：不保存截图、不上传、不录音、不注入文字。
            if result.source != "window" { fputs("Preview window capture failed\n", stderr) }
            app.stop(nil)
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
            if let event { app.postEvent(event, atStart: true) }
        }
    }
    app.run()
    exit(0)
}
// 显式启动的付费历史加速对比：不启动UI/监听/录音，不改真实历史，不回填。
if let flag = CommandLine.arguments.firstIndex(of: "--audio-speed-benchmark"), flag + 1 < CommandLine.arguments.count {
    let output = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    Task {
        do { try await AudioSpeedBenchmark.run(output: output); exit(0) }
        catch { fputs("加速对比未完成：\(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
}
let application = NSApplication.shared
let delegate = VoiceApp()
application.delegate = delegate
application.run()
