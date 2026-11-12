import AppKit
import ApplicationServices

struct MouseHoldGesture {
    var origin = CGPoint.zero
    var down = false
    var moved = false
    var active = false
    var enter = false
    mutating func begin(_ point: CGPoint) { origin = point; down = true; moved = false; active = false; enter = false }
    /// 录音中按右键:记下"松开后回车",并告知调用方拦截这次右键。
    mutating func rightClick() -> Bool { guard active else { return false }; enter = true; return true }
    mutating func move(_ point: CGPoint) {
        if down && !active && hypot(point.x - origin.x,point.y - origin.y) > 6 { moved = true }
    }
    var eligible: Bool { down && !moved && !active }
    mutating func reset() { down = false; moved = false; active = false; enter = false }
}

struct InputHit {
    let editable: Bool
    let description: String
}

enum EditableInput {
    private static func string(_ element: AXUIElement, _ key: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return "" }
        return value as? String ?? ""
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
        return value
    }
    private static func check(_ element: AXUIElement, at point: CGPoint) -> InputHit {
        AXUIElementSetMessagingTimeout(element,0.08)
        let role = string(element,kAXRoleAttribute)
        if string(element,kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return InputHit(editable:false,description:"安全输入框") }
        var names: CFArray?
        let attributes = AXUIElementCopyAttributeNames(element, &names) == .success ? (names as? [String] ?? []) : []
        let nativeText = [kAXTextFieldRole,kAXTextAreaRole,kAXComboBoxRole,"AXSearchField"].contains(role)
        // Electron 的普通容器可能代理焦点输入框的可写属性，不能仅凭 valueWritable 接受。
        let focusedEditor = attributes.contains(kAXSelectedTextRangeAttribute)
            && (attribute(element,kAXFocusedAttribute) as? Bool == true)
            && (attribute(element,"AXEditable") as? Bool == true)
            && role != "AXWebArea"
        let textual = nativeText || focusedEditor
        guard textual else { return InputHit(editable:false,description:role) }
        guard let position = attribute(element,kAXPositionAttribute),
              let size = attribute(element,kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            return InputHit(editable:false,description:"输入区域范围不可用")
        }
        var origin = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&origin),
              AXValueGetValue(size as! AXValue,.cgSize,&extent),
              extent.width > 0, extent.height > 0,
              CGRect(origin:origin,size:extent).contains(point) else {
            return InputHit(editable:false,description:"鼠标不在输入区域内")
        }
        if let enabled = attribute(element,kAXEnabledAttribute) as? Bool, !enabled { return InputHit(editable:false,description:"禁用输入框") }
        var writable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&writable)
        let editableFlag = attribute(element,"AXEditable") as? Bool ?? false
        return InputHit(editable: (result == .success && writable.boolValue) || editableFlag,description:"\(role),valueWritable=\(writable.boolValue)")
    }
    /// Chrome / Electron 类应用默认不开放界面树,要像读屏软件那样主动请求一次;每个进程只请求一次。
    private static var requested = Set<pid_t>()
    static func requestAccessibilityTree(pid: pid_t) -> Bool {
        guard pid > 0, !requested.contains(pid) else { return false }
        requested.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }
    static func hit(_ point: CGPoint) -> InputHit {
        guard AXIsProcessTrusted() else { return InputHit(editable:false,description:"无辅助功能权限") }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system,0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success, let hit else { return InputHit(editable:false,description:"无法读取鼠标下控件") }
        var element = hit
        var lastRole = ""
        for _ in 0..<8 {
            let role = string(element,kAXRoleAttribute)
            // 标题栏、工具栏和操作控件不能通过可编辑父节点或旧焦点兜底触发。
            if [kAXWindowRole,kAXApplicationRole,kAXToolbarRole,kAXButtonRole,kAXMenuBarRole,kAXMenuItemRole,kAXScrollBarRole,"AXTitleBar","AXSplitter"].contains(role) {
                return InputHit(editable:false,description:"非输入区域:\(role)")
            }
            let result = check(element,at:point); lastRole = result.description
            if result.editable { return result }
            if result.description == "安全输入框" { return result }
            guard let parent = attribute(element,kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return InputHit(editable:false,description:"未命中可编辑控件:\(lastRole)")
    }
}

final class MouseTrigger {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var gesture = MouseHoldGesture() { didSet { lock.lock(); intercepting = gesture.active; lock.unlock() } }
    private var generation = 0
    // 监听线程同步判断是否拦截右键;主线程改 gesture 时同步更新。
    private let lock = NSLock()
    private var intercepting = false
    private var rightClicked = false
    var enabled = true { didSet { if !enabled { cancel() } } }
    var canBegin: (() -> Bool)?
    /// 参数是按下的位置(屏幕坐标,原点左上),胶囊贴着它显示。
    var onBegin: ((CGPoint) -> Bool)?
    /// 参数为 true 表示录音中点过右键,输入完成后应自动回车。
    var onEnd: ((Bool) -> Void)?
    var recording: Bool { gesture.active }
    var active: Bool { tap != nil }
    func start() {
        guard tap == nil, CGPreflightListenEventAccess() else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _,type,event,pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let object = Unmanaged<MouseTrigger>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = object.tap { CGEvent.tapEnable(tap:tap,enable:true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .rightMouseDown || type == .rightMouseUp {
                // 录音中的右键整个吞掉,不弹右键菜单;按下即记为"松开后回车"。
                object.lock.lock(); let swallow = object.intercepting
                if swallow && type == .rightMouseDown { object.rightClicked = true }
                object.lock.unlock()
                return swallow ? nil : Unmanaged.passUnretained(event)
            }
            let point = event.location
            DispatchQueue.main.async { object.handle(type,point) }
            return Unmanaged.passUnretained(event) // 不拦截左键,保留正常点击与选字。
        }
        // 拦截右键需要主动式监听(辅助功能权限);没有权限时退回只听不拦,右键照常弹菜单。
        let options: CGEventTapOptions = AXIsProcessTrusted() ? .defaultTap : .listenOnly
        tap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:options,eventsOfInterest:CGEventMask(mask),callback:callback,userInfo:Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
            CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
            CGEvent.tapEnable(tap:tap,enable:true)
            Paths.log("鼠标长按监听已启动\(options == .defaultTap ? ",可拦截右键" : ",无辅助功能权限,不拦截右键")")
        }
    }
    func cancel() {
        generation += 1; timer?.invalidate(); timer = nil; gesture.reset()
        lock.lock(); rightClicked = false; lock.unlock()
    }
    func stop() {
        cancel()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil
    }
    private func handle(_ type: CGEventType, _ point: CGPoint) {
        guard enabled else { return }
        if type == .leftMouseDown {
            cancel()
            guard canBegin?() == true else { return }
            gesture.begin(point)
            let token = generation
            let timer = Timer(timeInterval:0.5,repeats:false) { [weak self] _ in self?.checkInput(point,token:token) }
            RunLoop.main.add(timer,forMode:.common); self.timer = timer
        } else if type == .leftMouseDragged {
            gesture.move(point)
            if gesture.moved { timer?.invalidate(); timer = nil; generation += 1 }
        } else if type == .leftMouseUp {
            let shouldEnd = gesture.active
            lock.lock(); let clicked = rightClicked; lock.unlock()
            if clicked, gesture.rightClick() { Paths.log("鼠标长按: 录音中点过右键,输入后自动回车") }
            let enter = gesture.enter
            cancel()
            if shouldEnd { onEnd?(enter) }
        }
    }
    private func checkInput(_ point: CGPoint, token: Int) {
        guard token == generation,gesture.eligible,canBegin?() == true else { return }
        // 原生窗口拖动可能占用事件循环，不能只依赖 leftMouseDragged 回调。
        guard CGEventSource.buttonState(.combinedSessionState, button:.left),
              let current = CGEvent(source:nil)?.location,
              hypot(current.x - point.x,current.y - point.y) <= 6 else { cancel(); return }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? "?"; let pid = front?.processIdentifier ?? 0
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var result = EditableInput.hit(point)
            var retried = false
            if !result.editable, EditableInput.requestAccessibilityTree(pid: pid) {
                usleep(120_000); result = EditableInput.hit(point); retried = true
            }
            DispatchQueue.main.async {
                guard let self, token == self.generation, self.gesture.eligible, self.canBegin?() == true else { return }
                guard CGEventSource.buttonState(.combinedSessionState, button:.left),
                      let current = CGEvent(source:nil)?.location,
                      hypot(current.x - point.x,current.y - point.y) <= 6 else { self.cancel(); return }
                Paths.log("鼠标长按判定[\(app)]: \(result.description),命中=\(result.editable)\(retried ? ",已请求开放界面树后重判" : "")")
                if result.editable { self.gesture.active = self.onBegin?(point) == true }
            }
        }
    }
}
