import AppKit
import ApplicationServices

/// 只读取输入目标身份，不读取用户已有正文。
struct InputDestination {
    let pid: pid_t
    let element: AXUIElement?
    let usesPaste: Bool
    /// Electron / Chromium 类应用:模拟输入走的是输入法提交通道,末尾一批字偶尔会被它的输入框丢掉,回填后要读回校验。
    var chromium = false
    private static var chromiumCache: [pid_t: Bool] = [:]
    static func hasChromiumFramework(_ names: [String]) -> Bool {
        names.contains { name in
            ["Electron Framework", "Chromium", "Chrome Framework", "Codex Framework"].contains { name.contains($0) }
        }
    }
    static func isChromium(_ app: NSRunningApplication) -> Bool {
        if let cached = chromiumCache[app.processIdentifier] { return cached }
        var result = false
        if let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
           let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) {
            result = hasChromiumFramework(names)
        }
        chromiumCache[app.processIdentifier] = result
        return result
    }
    static func capture() -> InputDestination? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let fallback = InputDestination(pid: app.processIdentifier, element: nil, usesPaste: true)
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.06)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return fallback }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.06)
        var owner: pid_t = 0; AXUIElementGetPid(element, &owner)
        guard owner == app.processIdentifier else { return nil }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return nil }
        let wechat = app.bundleIdentifier == "com.tencent.xinWeChat"
        return InputDestination(pid: owner, element: element, usesPaste: wechat, chromium: isChromium(app))
    }
    func isCurrent() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = Self.capture(), current.pid == pid else { return false }
        // 不暴露AX输入框的应用只能核对前台应用，另由操作监听防止误贴。
        if usesPaste { return true }
        guard let element, let currentElement = current.element else { return false }
        return CFEqual(currentElement, element)
    }
}

/// 复述守卫:模型偶尔把截图里的上一句原样吐回来。开头与上一条结果一致时先攒着不写,
/// 攒够或结束时再判定:几乎相同 → 整条丢弃;不同 → 放行并补写。
struct EchoGuard {
    let previous: String
    private(set) var held = ""
    private(set) var decided = false
    private(set) var blocked = false
    static let probe = 8, decideAt = 24
    init(previous: String) { self.previous = EchoGuard.normalize(previous) }
    static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }).lowercased()
    }
    /// 返回这次可以写出去的文字(可能为空:还在攒,或已判定为复述)。
    mutating func admit(_ part: String) -> String {
        if decided { return blocked ? "" : part }
        if previous.count < EchoGuard.probe { decided = true; return part }
        held += part
        let normalized = EchoGuard.normalize(held)
        if normalized.count < EchoGuard.probe {
            return ""
        }
        if !previous.hasPrefix(String(normalized.prefix(EchoGuard.probe))) { decided = true; let out = held; held = ""; return out }
        // 中途只和上一条同样长度的开头比;像复述就继续攒到结束再整句判定,不像就放行。
        if normalized.count >= EchoGuard.decideAt, !EchoGuard.similar(normalized, String(previous.prefix(normalized.count))) {
            decided = true; let out = held; held = ""; return out
        }
        if normalized.count > previous.count + 6 { decided = true; let out = held; held = ""; return out }
        return ""
    }
    /// 流结束时的最终判定,返回还没写出去的文字。
    mutating func flush() -> String {
        guard !decided else { return "" }
        decided = true
        let normalized = EchoGuard.normalize(held)
        blocked = !normalized.isEmpty && EchoGuard.similar(normalized, previous)
        let out = blocked ? "" : held; held = ""; return out
    }
    /// 编辑距离占较长一方不超过 20%,视为同一句话(容忍“的”“了”这类插删和同音字)。
    static func similar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count), current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return Double(previous[y.count]) <= Double(max(x.count, y.count)) * 0.20
    }
}

/// 回填期间拦下单独按的回车(不带修饰键、非程序注入),回填完成后补发一次;其余按键原样放行。
final class ReturnInterceptor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var swallowed = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return swallowed }
    init?() {
        guard AXIsProcessTrusted() else { return nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let object = Unmanaged<ReturnInterceptor>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = object.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.marker else { return Unmanaged.passUnretained(event) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == 36 || code == 76, event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty else { return Unmanaged.passUnretained(event) }
            if type == .keyDown { object.lock.lock(); object.swallowed += 1; object.lock.unlock() }
            return nil
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return nil }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil
    }
    deinit { stop() }
}

/// 网络接收通过 AsyncStream 入队，写入在独立的主线程任务消费，不阻塞接收后续 token。
@MainActor final class StreamingInput {
    let continuation: AsyncStream<String>.Continuation
    private var worker: Task<Void, Never>?
    private let destination: InputDestination?
    private var eventMonitor: Any?
    private var activationMonitor: NSObjectProtocol?
    private(set) var receivedText = ""
    private(set) var failure: String?
    private(set) var wroteFirst = false
    private(set) var copiedForRecovery = false
    private let timingOrigin: Double
    private var guardian: EchoGuard
    /// 结束后为 true 表示整条结果被判定为复述上一句,未写入。
    private(set) var echoBlocked = false
    private var returnInterceptor: ReturnInterceptor?
    /// 回填期间用户按过回车(已拦下),完成后要补发。
    private(set) var returnHeld = false
    /// 实际打进输入框的文字(含“接着说”补的前缀),回填后用来和输入框读回的内容对末尾。
    private(set) var typedText = ""

    init(destination: InputDestination?, timingOrigin: Double, previousText: String = "") {
        self.destination = destination; self.timingOrigin = timingOrigin; guardian = EchoGuard(previous: previousText)
        var captured: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { captured = $0 }
        continuation = captured
        if destination == nil { failure = "无法确认原输入目标，结果已保留在历史" }
        // 单独按的回车由拦截器吞掉、打完再发;其他按键和鼠标仍视为操作改变、停止回填。
        returnInterceptor = destination?.usesPaste == true ? nil : ReturnInterceptor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.marker else { return }
            if event.type == .keyDown, (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty, self?.returnInterceptor != nil { return }
            self?.stopWriting("输入位置或操作已改变，已停止回填；完整结果保留在历史")
        }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard let self, app.processIdentifier != self.destination?.pid else { return }
                self.stopWriting("前台应用已改变，已停止回填；完整结果保留在历史")
            }
        }
        worker = Task { @MainActor [weak self] in
            for await part in stream {
                guard let self else { break }
                self.receivedText += part
                guard self.failure == nil, self.destination?.usesPaste != true else { continue }
                let admitted = self.guardian.admit(part)
                guard !admitted.isEmpty else { continue }
                do {
                    try await TextInput.insert(admitted, canWrite: { self.failure == nil && self.destination?.isCurrent() == true })
                    self.typedText += admitted
                    if !self.wroteFirst {
                        self.wroteFirst = true
                        Paths.log("首次流式写入: \(Int((ProcessInfo.processInfo.systemUptime-self.timingOrigin)*1000))ms")
                    }
                } catch { self.stopWriting(error.localizedDescription) }
            }
        }
    }
    private func stopWriting(_ message: String) { if failure == nil { failure = message } }
    /// Electron 类应用回填后读回输入框,确认末尾和打进去的一致;不一致且只差最后一小截就补打一次。只记字数,不记文字。
    private func settle() async {
        guard failure == nil, let destination, destination.chromium, !destination.usesPaste, !typedText.isEmpty else { return }
        // 补打是在恢复原全文，不能把补打部分再计入预期内容。
        let expectedText = typedText
        let started = ProcessInfo.processInfo.systemUptime
        var missing: String?, readable = false, polls = 0
        while true {
            guard failure == nil, destination.isCurrent() else { return }
            polls += 1
            if let value = FieldReader.value(of: destination.element) {
                readable = true
                missing = FillVerifier.missingTail(typed: expectedText, field: value)
                if missing == "" {
                    if polls > 1 { Paths.log("回填校验: 第 \(polls) 次读回才齐,等了 \(Int((ProcessInfo.processInfo.systemUptime-started)*1000))ms") }
                    return
                }
            }
            if ProcessInfo.processInfo.systemUptime - started >= 0.6 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard readable else { Paths.log("回填校验: 读不到输入框内容,跳过"); return }
        guard let missing else { Paths.log("回填校验: 输入框内容和打进去的对不上,跳过(共 \(expectedText.count) 字)"); return }
        guard missing.count <= 40 else { Paths.log("回填校验: 输入框末尾少 \(missing.count) 字,超出补打范围,不动"); return }
        do {
            try await TextInput.insert(missing, canWrite: { self.failure == nil && destination.isCurrent() })
            try? await Task.sleep(nanoseconds: 150_000_000)
            let again = FieldReader.value(of: destination.element).flatMap { FillVerifier.missingTail(typed: expectedText, field: $0) }
            Paths.log("回填校验: 输入框末尾少 \(missing.count) 字,已补打,复查=\(again == "" ? "齐了" : "仍不齐")")
        } catch { Paths.log("回填校验: 补打失败 \(error.localizedDescription)") }
    }
    func finish(sendReturn: Bool, finalText: String? = nil) async {
        continuation.finish()
        await worker?.value
        let rest = guardian.flush()
        echoBlocked = guardian.blocked
        if echoBlocked {
            Paths.log("复述守卫: 结果与上一条几乎相同,未写入")
            returnInterceptor?.stop(); returnInterceptor = nil
            return
        }
        if !rest.isEmpty, failure == nil, destination?.usesPaste != true {
            do { try await TextInput.insert(rest, canWrite: { self.failure == nil && self.destination?.isCurrent() == true }); typedText += rest; wroteFirst = true }
            catch { stopWriting(error.localizedDescription) }
        }
        // 回车拦截器要等校验结束再撤:校验期间按的回车同样攒着,确保字全落地了再发。
        await settle()
        returnHeld = (returnInterceptor?.count ?? 0) > 0
        returnInterceptor?.stop(); returnInterceptor = nil
        if returnHeld { Paths.log("回填途中按了回车,打完后补发") }
        let sendReturn = sendReturn || returnHeld
        // 仅成功拿到完整结果才粘贴；失败/取消不提交残缺文本。
        if let finalText, !finalText.isEmpty, destination?.usesPaste == true, failure == nil, !EchoGuard.similar(EchoGuard.normalize(finalText), guardian.previous) {
            do {
                try await TextInput.paste(finalText, canWrite: { self.failure == nil && self.destination?.isCurrent() == true })
                wroteFirst = true
            } catch { stopWriting(error.localizedDescription) }
        }
        if sendReturn && wroteFirst && failure == nil {
            do { try await TextInput.pressReturn(canWrite: { self.failure == nil && self.destination?.isCurrent() == true }) }
            catch { stopWriting(error.localizedDescription) }
        }
        if let finalText, !finalText.isEmpty, failure != nil {
            let board = NSPasteboard.general
            board.clearContents()
            copiedForRecovery = board.setString(finalText, forType: .string)
        }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let activationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(activationMonitor); self.activationMonitor = nil }
        returnInterceptor?.stop(); returnInterceptor = nil
    }
}

/// 回填校验:比较“打进去的文字”和“输入框读回的内容”的末尾。
enum FillVerifier {
    private static func squeeze(_ text: String) -> [Character] { text.filter { !$0.isWhitespace && !$0.isNewline } }
    /// 返回输入框末尾缺的那截:"" 表示齐全;nil 表示对不上(输入框末尾连打进去的开头都没有,不能判断)。
    /// 比较时忽略空白和换行,因为不同输入框对换行的表示不一样。
    static func missingTail(typed: String, field: String) -> String? {
        let t = squeeze(typed), f = squeeze(field)
        guard !t.isEmpty else { return "" }
        var k = min(t.count, f.count)
        while k > 0 {
            if f.suffix(k).elementsEqual(t.prefix(k)) { break }
            k -= 1
        }
        guard k > 0 else { return nil }
        if k == t.count { return "" }
        // 把“前 k 个非空白字符”映射回原文位置,缺的就是其后的部分。
        var seen = 0
        for (index, character) in typed.enumerated() where !character.isWhitespace && !character.isNewline {
            seen += 1
            if seen == k { return String(typed.dropFirst(index + 1)) }
        }
        return ""
    }
}

/// 接着说补标点:开了“去掉末尾标点”后,同一输入框 2 分钟内接着说下一句、中间没有真实按键或点击,先把上一句去掉的标点补回;英文之间补空格。
struct ContinuationState {
    var pid: pid_t = 0
    var element: AXUIElement?
    var strippedTail = ""        // 上一句被去掉的末尾标点
    var lastEndedWithLatin = false
    var at: Double = 0
    var invalidated = true
    static let window: Double = 120
    /// 上一句写完后记录。
    mutating func remember(destination: InputDestination?, originalText: String, writtenText: String, now: Double) {
        guard let destination, !writtenText.isEmpty else { invalidated = true; return }
        pid = destination.pid; element = destination.element; at = now; invalidated = false
        let tail = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        strippedTail = tail.hasPrefix(writtenText) ? String(tail.dropFirst(writtenText.count)) : ""
        lastEndedWithLatin = writtenText.last.map { $0.isLetter && $0.isASCII } ?? false
    }
    /// 用户在中间按了键或点了鼠标,就不再算“接着说”。
    mutating func invalidate() { invalidated = true }
    /// 下一句开始写之前,返回要先补的前缀。
    func prefix(for destination: InputDestination?, nextText: String, now: Double) -> String {
        guard !invalidated, let destination, destination.pid == pid, now - at <= ContinuationState.window else { return "" }
        if let element, let current = destination.element, !CFEqual(element, current) { return "" }
        if element == nil && destination.element != nil { return "" }
        var out = strippedTail
        let nextStartsLatin = nextText.first.map { $0.isLetter && $0.isASCII } ?? false
        if lastEndedWithLatin && nextStartsLatin { out += out.isEmpty ? " " : (out.last.map { ".,;:!?".contains($0) } == true ? " " : "") }
        return out
    }
}


/// 只发布稳定前缀：保留未结束的标记及尾部空白/标点，后续正文到来时再释放。
struct StreamingTranscript {
    var raw = ""
    var emitted = ""
    let stripPunctuation: Bool
    private let punctuation = CharacterSet(charactersIn: "。，、；：！？…～.,;:!?~ \n")
    mutating func append(_ part: String) -> String {
        raw += part
        let text = cleaned(final: false)
        // 仅缓冲可能的空语音回复开头；正常正文无需等待整句。
        let ambiguous = ["空", "无", "空白", "空字符串", "无内容", "空内容", "null", "none", "empty", "n/a", "没有", "未", "听不清", "无法", "不清晰", "不包含", "静音"]
        if emitted.isEmpty && text.count <= 12 && (ambiguous.contains(where: { $0.hasPrefix(text.lowercased()) }) || Recognition.looksLikeNoSpeech(text)) { return "" }
        return release(text)
    }
    mutating func finish(_ validatedText: String) -> String { release(validatedText) }
    private mutating func release(_ text: String) -> String {
        guard text.hasPrefix(emitted) else { return "" }
        let delta = String(text.dropFirst(emitted.count)); emitted = text
        return delta
    }
    func cleaned(final: Bool) -> String {
        var rest = raw[...], visible = "", thinking = false
        while !rest.isEmpty {
            if rest.hasPrefix("<think>") { thinking = true; rest = rest.dropFirst(7); continue }
            if rest.hasPrefix("</think>") { thinking = false; rest = rest.dropFirst(8); continue }
            if !final && ("<think>".hasPrefix(rest) || "</think>".hasPrefix(rest)) { break }
            let character = rest.removeFirst()
            if !thinking { visible.append(character) }
        }
        visible = visible.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if stripPunctuation { visible = visible.trimmingCharacters(in: punctuation) }
        return visible
    }
}

/// 纠错学习:对比“程序打进去的”和“用户改完的”,找出被替换的词对。纯本地,不依赖模型。
enum CorrectionLearner {
    struct Correction: Equatable { let from: String; let to: String }
    /// 在用户改完的全文里定位程序打的那一段(可能前后还有别的文字),返回对应的新文字。
    static func locate(written: String, in current: String) -> String? {
        guard !written.isEmpty, !current.isEmpty else { return nil }
        if current.contains(written) { return written }   // 没改
        let w = Array(written), c = Array(current)
        // 用首尾各 4 个字锚定;首尾都被改时放弃。
        let head = Array(w.prefix(min(4, w.count))), tail = Array(w.suffix(min(4, w.count)))
        guard let start = find(head, in: c, from: 0) else { return nil }
        guard let end = find(tail, in: c, from: start + head.count) else { return nil }
        let slice = c[start..<(end + tail.count)]
        guard slice.count <= w.count + 20, slice.count >= max(2, w.count - 20) else { return nil }
        return String(slice)
    }
    private static func find(_ needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= hay.count { if Array(hay[i..<(i + needle.count)]) == needle { return i }; i += 1 }
        return nil
    }
    /// 词级差异:公共前缀、公共后缀之外的中间段就是替换对;只认一处替换、长度 1～12。
    static func diff(written: String, edited: String) -> Correction? {
        let a = Array(written), b = Array(edited)
        guard a != b else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var sa = a.count, sb = b.count
        while sa > p, sb > p, a[sa - 1] == b[sb - 1] { sa -= 1; sb -= 1 }
        var from = String(a[p..<sa]), to = String(b[p..<sb])
        // 扩到词边界:中文按字,英文/数字按整段字母数字
        func expand() {
            var lp = p, rp = sa
            func alnum(_ ch: Character) -> Bool { ch.isLetter && ch.isASCII || ch.isNumber }
            while lp > 0, alnum(a[lp - 1]), (from.first.map(alnum) ?? true) { lp -= 1 }
            while rp < a.count, alnum(a[rp]), (from.last.map(alnum) ?? true) { rp += 1 }
            let delta = (p - lp, rp - sa)
            from = String(a[lp..<rp]); to = String(b[(p - delta.0)..<(sb + delta.1)])
        }
        expand()
        let punct = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)
        from = from.trimmingCharacters(in: punct); to = to.trimmingCharacters(in: punct)
        guard !to.isEmpty, (1...12).contains(to.count), to != from else { return nil }
        guard !from.isEmpty, from.count <= 12 else { return nil }      // 纯新增/整句重写不算
        guard to.rangeOfCharacter(from: .letters) != nil else { return nil }
        return Correction(from: from, to: to)
    }
}
