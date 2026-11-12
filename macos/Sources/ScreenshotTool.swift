import AppKit
import Carbon
import ScreenCaptureKit

/// 独立截图工具：系统注册热键，调用原生交互截图，不写入历史或调用模型。
/// 通用全局热键(Carbon):一个组合键,松开时触发;注册失败返回说明。
final class GlobalHotkey {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType
    var onTrigger: (() -> Void)?
    init(signature: OSType) { self.signature = signature }
    func configure(_ shortcut: String) -> String? {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        guard !shortcut.isEmpty else { return nil }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, pointer in
                guard let pointer, let eventRef else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let object = Unmanaged<GlobalHotkey>.fromOpaque(pointer).takeUnretainedValue()
                guard id.signature == object.signature else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { object.onTrigger?() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "快捷键注册失败" }
        }
        do {
            let (key, modifiers) = try ScreenshotTool.binding(shortcut)
            var ref: EventHotKeyRef?
            guard RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr, let ref else { return "快捷键被其他应用占用,换一个组合" }
            hotkey = ref
        } catch { return error.localizedDescription }
        return nil
    }
}

final class ScreenshotTool {
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var process: Process?
    private var editors: [ScreenshotMarkupWindow] = []
    private var preparation: Task<Void, Never>?
    private var captureID: UUID?
    var onTrigger: (() -> Void)?
    var onComplete: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var isRunning: Bool { process != nil || captureID != nil }
    static func binding(_ text: String) throws -> (UInt32, UInt32) {
        let groups = try HotkeyMonitor.parse(text)
        var modifiers: UInt32 = 0
        var keys: [UInt32] = []
        for group in groups {
            if !group.isDisjoint(with: [54,55]) { modifiers |= UInt32(cmdKey) }
            else if !group.isDisjoint(with: [56,60]) { modifiers |= UInt32(shiftKey) }
            else if !group.isDisjoint(with: [58,61]) { modifiers |= UInt32(optionKey) }
            else if !group.isDisjoint(with: [59,62]) { modifiers |= UInt32(controlKey) }
            else if let key = group.first, group.count == 1, key != 63, key != 53 { keys.append(UInt32(key)) }
            else { throw VoiceError(message: "请使用修饰键加字母或功能键") }
        }
        guard keys.count == 1, modifiers != 0 else { throw VoiceError(message: "请使用修饰键加一个字母或功能键") }
        return (keys[0], modifiers)
    }
    func configure(_ shortcuts: [String]) -> String? {
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
                guard let pointer else { return OSStatus(eventNotHandledErr) }
                let tool = Unmanaged<ScreenshotTool>.fromOpaque(pointer).takeUnretainedValue()
                DispatchQueue.main.async { tool.onTrigger?() }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return "截图快捷键注册失败" }
        }
        var errors: [String] = []
        var registered = Set<String>()
        for (index, text) in shortcuts.enumerated() where !text.isEmpty {
            do {
                let (key, modifiers) = try Self.binding(text)
                guard registered.insert("\(key):\(modifiers)").inserted else { continue }
                var hotkey: EventHotKeyRef?
                let id = EventHotKeyID(signature: 0x44565343, id: UInt32(index+1))
                if RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotkey) == noErr, let hotkey {
                    hotkeys.append(hotkey)
                } else { errors.append("截图快捷键 \(index+1) 被占用，请关闭微信对应快捷键或更换组合") }
            } catch { errors.append("截图快捷键 \(index+1)：\(error.localizedDescription)") }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
    func capture(markup: Bool = false) {
        guard !isRunning else { return }
        if markup { beginMarkup(); return }
        let before = NSPasteboard.general.changeCount
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-c", "-x"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.process = nil
                let copied = task.terminationStatus == 0 && NSPasteboard.general.changeCount != before &&
                    NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
                self.onComplete?(copied)
            }
        }
        process = task
        do { try task.run() }
        catch { process = nil; onError?("无法打开系统截图工具"); onComplete?(false) }
    }
    private func beginMarkup() {
        guard #available(macOS 14.0, *) else { onError?("截图标记需要 macOS 14 或更新版本"); onComplete?(false); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            onError?("请开启屏幕录制权限后重试截图"); onComplete?(false); return
        }
        let id = UUID(); captureID = id
        let previous = NSWorkspace.shared.frontmostApplication
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                var shots: [(CGImage, NSRect)] = []
                for screen in NSScreen.screens {
                    try Task.checkCancellation()
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    shots.append((image,screen.frame))
                }
                try Task.checkCancellation()
                guard self.captureID == id else { return }
                guard !shots.isEmpty else { throw VoiceError(message: "未找到可截图的屏幕") }
                let pointer = NSEvent.mouseLocation
                for (image,frame) in shots {
                    let controller = ScreenshotMarkupWindow(image: image, screenFrame: frame) { [weak self] result in
                        guard let self, self.captureID == id else { return }
                        var copied = false
                        if let result { NSPasteboard.general.clearContents(); copied = NSPasteboard.general.writeObjects([result]) }
                        self.endMarkup()
                        if NSApp.isActive, previous?.processIdentifier != getpid() { previous?.activate(options: []) }
                        self.onComplete?(copied)
                    }
                    controller.onSelected = { [weak self, weak controller] in
                        guard let self else { return }
                        for other in self.editors where other !== controller { other.window?.ignoresMouseEvents = true }
                    }
                    self.editors.append(controller)
                }
                NSApp.activate(ignoringOtherApps: true)
                for controller in self.editors { controller.present(key: controller.window?.frame.contains(pointer) == true) }
                self.preparation = nil
            } catch {
                guard self.captureID == id else { return }
                self.endMarkup()
                self.onError?("截图未完成，请检查屏幕录制权限后重试")
                self.onComplete?(false)
            }
        }
    }
    private func endMarkup() {
        captureID = nil; preparation?.cancel(); preparation = nil
        let closing = editors; editors.removeAll()
        for editor in closing { editor.close() }
    }
    func stop() {
        process?.terminate(); process = nil; endMarkup()
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }; hotkeys.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit { stop() }
}
