import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotResult {
    var jpeg: Data?
    var source: String? = nil
    var note: String? = nil
}

/// 每次录音独享一个任务；只在内存中准备图像，取消/超时后迟到的回调不会落盘。
final class ScreenshotJob: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ScreenshotResult?
    private var waiters: [CheckedContinuation<ScreenshotResult, Never>] = []
    private var worker: Task<Void, Never>?
    init(operation: @escaping @Sendable () async -> ScreenshotResult, timeout: Double = 8) {
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await operation()
            self?.resolve(result)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(ScreenshotResult(note: "截图超时，本次仅使用录音"))
        }
    }
    private func resolve(_ value: ScreenshotResult) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiting = waiters; waiters.removeAll(); let task = worker
        lock.unlock()
        task?.cancel()
        for continuation in waiting { continuation.resume(returning: value) }
    }
    func value() async -> ScreenshotResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(returning: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func cancel() { resolve(ScreenshotResult(note: "截图已取消")) }
}

enum WindowScreenshot {
    static let maxEdge: CGFloat = 1280
    static func dimensions(_ size: CGSize) -> (Int, Int) {
        let scale = min(1, maxEdge / max(1, max(size.width, size.height)))
        return (max(1, Int(size.width * scale)), max(1, Int(size.height * scale)))
    }
    static func compress(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let (width, height) = dimensions(CGSize(width: image.width, height: image.height))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoiceError(message: "截图处理失败") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw VoiceError(message: "截图处理失败") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw VoiceError(message: "截图编码失败") }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw VoiceError(message: "截图编码失败") }
        return bytes as Data
    }
    static func capture(pid: pid_t, pointer: CGPoint, desktopTop: CGFloat) async -> ScreenshotResult {
        guard CGPreflightScreenCaptureAccess() else { return ScreenshotResult(note: "截图权限未开启，本次仅使用录音") }
        guard #available(macOS 14.0, *) else { return ScreenshotResult(note: "窗口截图需要 macOS 14 或更新版本") }
        do {
            try Task.checkCancellation()
            // 把触发时应用的窗口 ID 固定下来，不在录音结束后重新寻找前台窗口。
            let focus = FrontWindowLocator.rect(pid: pid, desktopTop: desktopTop).map {
                CGRect(x: $0.minX, y: desktopTop - $0.maxY, width: $0.width, height: $0.height)
            }
            let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let candidates = listed.filter {
                ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0
            }
            let target = candidates.first { item in
                guard let focus, let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                return abs(rect.minX - focus.minX) < 4 && abs(rect.minY - focus.minY) < 4 && abs(rect.width - focus.width) < 4 && abs(rect.height - focus.height) < 4
            }
            // 辅助功能取不到时，普通应用仍可用窗口列表；Finder 桌面不能误选后台文件窗口。
            let finder = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
            let fallback = focus == nil && !finder ? candidates.first : nil
            let targetID = (target ?? fallback)?[kCGWindowNumber as String] as? UInt32
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            let filter: SCContentFilter
            let size: CGSize
            let source: String
            if let targetID, let window = content.windows.first(where: { $0.windowID == targetID }), window.frame.width > 1, window.frame.height > 1 {
                filter = SCContentFilter(desktopIndependentWindow: window); size = window.frame.size; source = "window"
            } else {
                guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) else {
                    return ScreenshotResult(note: "未找到鼠标所在屏幕，本次仅使用录音")
                }
                // 避免录音胶囊或本应用的浮窗进入整屏回退截图。
                let own = content.applications.filter { $0.processID == getpid() }
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                size = display.frame.size; source = "display"
            }
            let config = SCStreamConfiguration()
            let (width, height) = dimensions(size)
            config.width = width; config.height = height; config.showsCursor = false
            config.scalesToFit = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            let data = try compress(image)
            Paths.log("截图准备: source=\(source) bytes=\(data.count)")
            return ScreenshotResult(jpeg: data, source: source)
        } catch {
            // 不记录窗口标题、截图内容或系统返回的敏感信息。
            return ScreenshotResult(note: "截图未完成，本次仅使用录音")
        }
    }
}
