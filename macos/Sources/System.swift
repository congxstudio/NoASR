import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import AudioToolbox

struct Microphone {
    var id: AudioDeviceID
    var name: String
    var uid: String
    var transport: UInt32 = 0
    /// 自动选择的优先级:有线/USB 0,内置 1,蓝牙 2;虚拟、聚合、iPhone 等不自动选择。
    var rank: Int? {
        switch transport {
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort: return 0
        case kAudioDeviceTransportTypeBuiltIn: return 1
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 2
        default: return nil
        }
    }
    /// 蓝牙麦克风会让耳机切到通话模式(约0.7秒,且耳机里听不到提示音),所以排在最后。同级优先系统默认。
    static func preferred(_ devices: [Microphone], defaultID: AudioDeviceID) -> Microphone? {
        devices.filter { $0.rank != nil }.min { a, b in
            a.rank! != b.rank! ? a.rank! < b.rank! : a.id == defaultID && b.id != defaultID
        }
    }
    static func defaultID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&id)
        return id
    }
    static func list() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
            guard let name else { return nil }
            var uidAddress = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            _ = AudioObjectGetPropertyData(id,&uidAddress,0,nil,&uidSize,&uid)
            var transportAddress = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyTransportType,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id,&transportAddress,0,nil,&transportSize,&transport)
            return Microphone(id: id, name: name.takeRetainedValue() as String, uid: uid?.takeRetainedValue() as String? ?? "", transport: transport)
        }
    }
}

struct CapturedAudio: Sendable {
    let url: URL
    let duration: Double
    let voiced: Double
}

private final class CaptureSession {
    var file: AVAudioFile?
    let converter: AVAudioConverter
    let output: AVAudioFormat
    let url: URL
    var samples: AVAudioFramePosition = 0
    var voiced: Double = 0
    var error: Error?
    init(input: AVAudioFormat, url: URL) throws {
        self.url = url
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw VoiceError(message: "麦克风不支持音频转换") }
        self.output = output; self.converter = converter
        self.file = try AVAudioFile(forWriting: url, settings: output.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }
    func append(_ buffer: AVAudioPCMBuffer, level: @escaping (Double) -> Void) {
        guard error == nil, file != nil else { return }
        if let samples = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(Double(sum) / Double(max(1, buffer.frameLength)))
            let db = 20 * log10(rms + 1e-7)
            if db > -45 { voiced += Double(buffer.frameLength) / buffer.format.sampleRate }
            level(min(1, max(0, (db + 55) / 40)))
        }
        let count = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: count) else { return }
        var provided = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true; status.pointee = .haveData; return buffer
        }
        if let conversionError { error = conversionError; return }
        do {
            if converted.frameLength > 0 { try file?.write(from: converted); samples += AVAudioFramePosition(converted.frameLength) }
        } catch { self.error = error }
    }
}

/// 直接打开指定麦克风(AUHAL)。AVAudioEngine 会先接上系统默认麦克风,默认是蓝牙耳机时会让耳机白白切一次通话模式。
private final class InputUnit {
    let unit: AudioUnit
    let format: AVAudioFormat
    let device: AudioDeviceID
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var callbacks = 0
    private var reported = false
    init(device: AudioDeviceID) throws {
        self.device = device
        func check(_ status: OSStatus, _ step: String) throws {
            guard status == noErr else { Paths.log("麦克风\(step)失败: \(status)"); throw VoiceError(message: "无法打开麦克风,请在设置中换一个麦克风") }
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw VoiceError(message: "没有可用的录音组件") }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "创建")
        guard let unit = created else { throw VoiceError(message: "没有可用的录音组件") }
        do {
            var on: UInt32 = 1, off: UInt32 = 0, id = device
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), "开启输入")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), "关闭输出")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "选择设备")
            var hardware = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "读取格式")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) else { throw VoiceError(message: "没有可用麦克风") }
            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "设置格式")
            // 声音块缩到 256 帧(48kHz 下约 5ms),第一段声音更早到;设不成也不影响。
            var frames: UInt32 = 256
            _ = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, flagSize)
            self.unit = unit; self.format = format
        } catch { AudioComponentInstanceDispose(unit); throw error }
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timestamp, bus, frames, _ in
            Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        do {
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "设置回调")
            try check(AudioUnitInitialize(unit), "初始化")
        } catch { AudioComponentInstanceDispose(unit); throw error }
    }
    func start() throws {
        callbacks = 0; reported = false
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { Paths.log("麦克风启动失败: \(status)"); throw VoiceError(message: "无法打开麦克风,请在设置中换一个麦克风") }
    }
    /// 只停止采集,组件留着下次直接启动(停止后不占用麦克风,系统橙点熄灭)。
    func pause() { AudioOutputUnitStop(unit); onBuffer = nil }
    func stop() {
        AudioOutputUnitStop(unit); onBuffer = nil; AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
    }
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timestamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        callbacks += 1
        if callbacks == 1 { Paths.log("麦克风[回调] 首次 frames=\(frames)") }
        // 按 AUHAL 约定传入 mData 为空的缓冲区列表,由系统提供内部缓冲区再拷贝;自带缓冲区会报 -50。
        let channels = Int(format.channelCount)
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(list.unsafeMutablePointer) }
        list.count = channels
        for index in 0..<channels { list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size), mData: nil) }
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list.unsafeMutablePointer)
        guard status == noErr else { report("读取失败 \(status)"); return status }
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let target = copy.floatChannelData else { report("缓冲区异常"); return noErr }
        copy.frameLength = frames
        for channel in 0..<channels {
            guard let data = list[channel].mData else { report("系统缓冲区为空"); return noErr }
            target[channel].update(from: data.assumingMemoryBound(to: Float.self), count: Int(frames))
        }
        onBuffer?(copy)
        return noErr
    }
    private func report(_ text: String) {
        guard !reported else { return }
        reported = true; Paths.log("麦克风[回调] \(text)")
    }
}

// current 只由串行 audio queue 访问;onLevel 在启动前设置,回调总在主队列。
final class Recorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.daiwen.voice-input.audio")
    private var current: (input: InputUnit, capture: CaptureSession)?
    /// 空闲时留着的已初始化组件,按下热键时省掉约 25ms 初始化;设备不同时重建。
    private var spare: InputUnit?
    var onLevel: ((Double) -> Void)?
    private func choose(device: String, uid: String) -> (id: AudioDeviceID, name: String, manual: Bool) {
        let devices = Microphone.list()
        let selected = !uid.isEmpty ? devices.first(where: { $0.uid == uid }) : devices.first(where: { $0.name == device && !device.isEmpty })
        if (!uid.isEmpty || !device.isEmpty) && selected == nil { Paths.log("指定麦克风未连接,本次自动选择") }
        let defaultID = Microphone.defaultID()
        let chosen = selected ?? Microphone.preferred(devices, defaultID: defaultID)
        return (chosen?.id ?? defaultID, chosen?.name ?? devices.first(where: { $0.id == defaultID })?.name ?? "系统默认", selected != nil)
    }
    /// 空闲时提前准备好所选麦克风的组件。启动、设置变化和每次录完都会调用。
    func prepare(device: String, uid: String = "") {
        queue.async {
            guard self.current == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            let target = self.choose(device: device, uid: uid)
            if let spare = self.spare, spare.device == target.id { return }
            self.spare?.stop(); self.spare = nil
            if let unit = try? InputUnit(device: target.id) { self.spare = unit; Paths.log("麦克风[预备] \(target.name)") }
        }
    }
    /// 设备是否正在被采集(用于确认空闲时没有占用麦克风)。
    static func isRunning(device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }
    var idleDevice: AudioDeviceID? { spare?.device }
    static func checkConversion() throws -> Bool {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-conversion-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = try CaptureSession(input: input, url: url)
        for frame in 0..<8 {
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for channel in 0..<2 {
                for sample in 0..<4800 { buffer.floatChannelData![channel][sample] = frame == 0 ? 0 : Float(sin(Double(sample) * 2 * .pi * 440 / 48000) * 0.2) }
            }
            capture.append(buffer) { _ in }
        }
        capture.file = nil
        if let error = capture.error { throw error }
        let result = try AVAudioFile(forReading: url)
        return result.fileFormat.sampleRate == 16000 && result.fileFormat.channelCount == 1 && result.length > 10000 && capture.voiced > 0.6
    }
    /// 等第一段声音真正到达才返回,蓝牙耳机切换通话模式的时间也算在内,此后说的话不会丢。
    func start(device: String, uid: String = "") async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let begin = Date()
                func ms(_ since: Date = begin) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
                var input: InputUnit?
                var capture: CaptureSession?
                do {
                    guard self.current == nil else { throw VoiceError(message: "正在录音") }
                    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw VoiceError(message: "请先开启麦克风权限") }
                    let target = self.choose(device: device, uid: uid)
                    Paths.log("麦克风[选择] \(target.name)\(target.manual ? "(手动)" : "(自动)") \(ms())ms")
                    let created: InputUnit
                    if let spare = self.spare, spare.device == target.id { created = spare; self.spare = nil }
                    else { self.spare?.stop(); self.spare = nil; created = try InputUnit(device: target.id) }
                    input = created
                    Paths.log("麦克风[初始化] 采样率 \(Int(created.format.sampleRate)) 声道 \(created.format.channelCount) \(ms())ms")
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-input-\(UUID().uuidString).wav")
                    let session = try CaptureSession(input: created.format, url: url); capture = session
                    var waiting: CheckedContinuation<Void, Error>? = continuation
                    created.onBuffer = { buffer in
                        self.queue.async {
                            if let pending = waiting {
                                waiting = nil
                                Paths.log("麦克风[首段声音] \(ms())ms")
                                pending.resume()
                            }
                            session.append(buffer) { value in DispatchQueue.main.async { self.onLevel?(value) } }
                        }
                    }
                    let started = Date()
                    try created.start()
                    self.current = (created, session)
                    Paths.log("麦克风[启动] 用时 \(ms(started))ms,累计 \(ms())ms")
                    self.queue.asyncAfter(deadline: .now() + 4) {
                        guard let pending = waiting else { return }
                        waiting = nil
                        Paths.log("麦克风[超时] 4秒没有收到声音")
                        if let current = self.current, current.input === created {
                            created.stop(); session.file = nil; self.current = nil
                            try? FileManager.default.removeItem(at: url)
                        }
                        pending.resume(throwing: VoiceError(message: "麦克风没有声音传来,请检查麦克风"))
                    }
                } catch {
                    input?.stop(); capture?.file = nil
                    if let capture { try? FileManager.default.removeItem(at: capture.url) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    func stop(discard: Bool = false) async throws -> CapturedAudio? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let (input, context) = self.current else { continuation.resume(returning: nil); return }
                input.pause()
                self.spare?.stop(); self.spare = input
                context.file = nil
                self.current = nil
                Paths.log("麦克风已释放")
                let audio = CapturedAudio(url: context.url, duration: Double(context.samples) / 16000, voiced: context.voiced)
                if discard || context.error != nil { try? FileManager.default.removeItem(at: context.url) }
                if !discard, let error = context.error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: discard ? nil : audio) }
            }
        }
    }
}

struct KeyEvent {
    let code: CGKeyCode
    let down: Bool
    let time: Double
    var flags: UInt64 = 0
}

final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onEvent: ((KeyEvent) -> Void)?
    var active: Bool { tap != nil }
    static let marker: Int64 = 0x445649
    static let modifierFlags: [CGKeyCode: (UInt64, UInt64, UInt64)] = [
        54: (0x10, 0x100000, 0x18), 55: (0x08, 0x100000, 0x18),
        56: (0x02, 0x20000, 0x06), 60: (0x04, 0x20000, 0x06),
        58: (0x20, 0x80000, 0x60), 61: (0x40, 0x80000, 0x60),
        59: (0x01, 0x40000, 0x2001), 62: (0x2000, 0x40000, 0x2001),
        63: (0, 0x800000, 0)
    ]
    static func modifierDown(code: CGKeyCode, flags: UInt64) -> Bool {
        guard let (side, generic, group) = modifierFlags[code] else { return false }
        return flags & group != 0 ? flags & side != 0 : flags & generic != 0
    }
    func start() {
        guard tap == nil, CGPreflightListenEventAccess() else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.eventSourceUserData) != HotkeyMonitor.marker else { return Unmanaged.passUnretained(event) }
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            var down = type == .keyDown
            if type == .flagsChanged {
                guard HotkeyMonitor.modifierFlags[code] != nil else { return Unmanaged.passUnretained(event) }
                down = HotkeyMonitor.modifierDown(code: code, flags: event.flags.rawValue)
            }
            let key = KeyEvent(code: code, down: down, time: Double(event.timestamp) / 1e9, flags: event.flags.rawValue)
            DispatchQueue.main.async { monitor.onEvent?(key) }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Paths.log("原生热键监听已启动")
        } else { Paths.log("原生热键监听启动失败") }
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    static let keyTable: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,"space":49,"esc":53,"right command":54,"left command":55,"left shift":56,"left option":58,"left ctrl":59,"right shift":60,"right option":61,"right ctrl":62,"fn":63,"f8":100,"f9":101,"f10":109,"f12":111,"f1":122,"f2":120]
    /// 键码对应的热键名,设置里“录入”按键时用;不支持的键返回 nil。
    static func name(for code: CGKeyCode) -> String? { keyTable.first { $0.value == code }?.key }
    static func parse(_ text: String) throws -> [Set<CGKeyCode>] {
        let keys = keyTable
        let groups: [String: Set<CGKeyCode>] = ["ctrl":[59,62],"shift":[56,60],"option":[58,61],"command":[54,55]]
        let names = text.lowercased().replacingOccurrences(of: "control", with: "ctrl").replacingOccurrences(of: "alt", with: "option").replacingOccurrences(of: "cmd", with: "command").components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !names.isEmpty else { throw VoiceError(message: "热键不能为空") }
        return try names.map { name in
            if let group = groups[name] { return group }
            if let code = keys[name] { return [code] }
            throw VoiceError(message: "不支持的热键：\(name)")
        }
    }
}

enum TextInput {
    static func foreground() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return "" }
        return details(pid: app.processIdentifier, name: app.localizedName ?? "")
    }
    static func details(pid: pid_t, name: String) -> String {
        var result = name
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element,0.08)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&window) == .success, let window {
                let focused = window as! AXUIElement
                AXUIElementSetMessagingTimeout(focused,0.08)
                var title: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused,kAXTitleAttribute as CFString,&title) == .success, let value = title as? String, !value.isEmpty { result += "（\(value.prefix(80))）" }
            }
        }
        return result
    }
    @MainActor static func insert(_ text: String, canWrite: () -> Bool = { true }) async throws {
        guard AXIsProcessTrusted() else { throw VoiceError(message: "请开启辅助功能权限,结果已存入历史") }
        for _ in 0..<100 {
            let flags = CGEventSource.flagsState(.hidSystemState)
            if flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard CGEventSource.flagsState(.hidSystemState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty else { throw VoiceError(message: "请松开修饰键,结果已存入历史") }
        // 自己生成的 Shift+Enter 使用独立状态表，避免污染用户键盘状态检查。
        guard let source = CGEventSource(stateID: .privateState) else {
            throw VoiceError(message: "无法创建文字输入事件源")
        }
        // CGEvent 每次携带一小批 Unicode；不再每个字符固定等待2ms。
        var chunks: [(String, Bool)] = [], current = ""
        for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
            if character == "\n" {
                if !current.isEmpty { chunks.append((current, false)); current = "" }
                chunks.append(("", true))
            } else {
                let next = String(character)
                if current.utf16.count + next.utf16.count > 20 && !current.isEmpty {
                    chunks.append((current, false)); current = ""
                }
                current += next
            }
        }
        if !current.isEmpty { chunks.append((current, false)) }
        for (chunk, newline) in chunks {
            guard canWrite() else { throw VoiceError(message: "输入焦点已改变，已停止回填；完整结果保留在历史") }
            guard CGEventSource.flagsState(.hidSystemState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty else {
                throw VoiceError(message: "检测到键盘操作，已停止回填；完整结果保留在历史")
            }
            let units = Array(chunk.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: newline ? 36 : 0, keyDown: down) else { throw VoiceError(message: "无法创建文字输入事件") }
                event.flags = newline && down ? .maskShift : []
                event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.marker)
                if !newline { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
                event.post(tap: .cghidEventTap)
            }
            await Task.yield()
        }
    }
    /// AX不可用的应用一次粘贴完整结果，不模拟逐字输入。
    @MainActor static func paste(_ text: String, canWrite: () -> Bool) async throws {
        guard AXIsProcessTrusted() else { throw VoiceError(message: "请开启辅助功能权限,结果已存入历史") }
        for _ in 0..<100 {
            if CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard canWrite(), CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty else {
            throw VoiceError(message: "输入目标或按键状态已改变，结果已保留在历史")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw VoiceError(message: "无法创建粘贴事件")
        }
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw VoiceError(message: "无法准备粘贴内容，结果已保留在历史") }
        let writtenChange = board.changeCount
        down.flags = .maskCommand; up.flags = []
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.marker)
            event.post(tap: .cghidEventTap)
        }
        // 给接收应用读取剪贴板的时间；用户期间复制了新内容则不覆盖。
        try? await Task.sleep(nanoseconds: 300_000_000)
        if board.changeCount == writtenChange {
            board.clearContents()
            let items = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
    }
    /// 输入完成后补一个回车(不带 Shift,即发送),用于鼠标长按录音中点过右键的情况。
    @MainActor static func pressReturn(canWrite: () -> Bool = { true }) async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
        guard canWrite(), CGEventSource.flagsState(.hidSystemState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty else {
            throw VoiceError(message: "输入焦点或按键状态已改变，未自动发送")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw VoiceError(message: "无法创建回车事件源")
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down) else { throw VoiceError(message: "无法创建回车事件") }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.marker)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// 当前输入光标在屏幕上的位置(AppKit 坐标,原点左下),用来把悬浮胶囊放在光标附近;找不到返回 nil。
enum CaretLocator {
    static func rect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedRef as! AXUIElement; AXUIElementSetMessagingTimeout(focused, 0.05)
        var found: CGRect?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &boundsRef) == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                var bounds = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &bounds), bounds.height > 0, bounds.height < 200, bounds.width < 2000 { found = bounds }
            }
        }
        if found == nil {
            // 拿不到光标就退回输入框本身;很高的输入框只取顶部一行,免得胶囊跑到屏幕下方。
            var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXPositionAttribute as CFString, &positionRef) == .success,
               AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let positionRef, let sizeRef, CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                var origin = CGPoint.zero; var size = CGSize.zero
                if AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 {
                    found = CGRect(x: origin.x, y: origin.y, width: size.width, height: min(size.height, 60))
                }
            }
        }
        guard let ax = found, let primary = NSScreen.screens.first else { return nil }
        // 辅助功能坐标原点在主屏左上角,转成 AppKit 的左下角坐标。
        return CGRect(x: ax.minX, y: primary.frame.height - ax.maxY, width: ax.width, height: ax.height)
    }
}

/// 只读前台应用的焦点窗口几何，不读取标题或正文。
enum FrontWindowLocator {
    static func rect(pid: pid_t, desktopTop: CGFloat) -> CGRect? {
        guard pid > 0, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let window = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(x: point.x, y: desktopTop - point.y - dimensions.height, width: dimensions.width, height: dimensions.height)
    }
}

/// 读前台应用里选中的文字(辅助功能);拿不到时用 ⌘C 借剪贴板,读完恢复原剪贴板。
enum SelectionReader {
    static func read() async -> String {
        if AXIsProcessTrusted() {
            let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.08)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty { return text }
            }
        }
        // 借剪贴板:记下原内容,⌘C,读,恢复。
        let board = NSPasteboard.general
        let before = board.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
            return dict.isEmpty ? nil : dict
        } ?? []
        let count = board.changeCount
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return "" }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down) else { return "" }
            event.flags = .maskCommand; event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.marker); event.post(tap: .cghidEventTap)
        }
        var text = ""
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if board.changeCount != count { text = board.string(forType: .string) ?? ""; break }
        }
        board.clearContents()
        if !before.isEmpty {
            let items = before.map { dict -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in dict { item.setData(data, forType: type) }; return item }
            board.writeObjects(items)
        }
        return text
    }
}
/// 读焦点输入框的全文(仅纠错学习在回填后的短窗口内使用)。
enum FieldReader {
    static func value(of element: AXUIElement?) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let target: AXUIElement
        if let element { target = element } else {
            let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.08)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            target = focused as! AXUIElement
        }
        AXUIElementSetMessagingTimeout(target, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
