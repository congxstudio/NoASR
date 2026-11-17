import AppKit
import ImageIO

enum ScreenshotTests {
    static func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.89, green: 0.94, blue: 0.99, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 180, y: 180, width: 2040, height: 1240))
        for i in 0..<12 {
            context.setFillColor(CGColor(red: 0.35, green: 0.55, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 300, y: 300 + i * 80, width: 800 + (i % 3) * 200, height: 24))
        }
        return context.makeImage()!
    }
    static func run() async throws {
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError(message: "FAIL: \(name)") }; print("PASS: \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try WindowScreenshot.compress(fixture())
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try check(decoded.width == 1280 && decoded.height == 853, "单次JPEG编码保持比例与最长边1280")
        try check(WindowScreenshot.dimensions(CGSize(width: 300, height: 200)).0 == 300, "小图不放大")
        try check(WindowScreenshot.dimensions(CGSize(width: 900, height: 4000)).1 == 1280, "竖屏限制最长边")
        let audio = root.appendingPathComponent("fixture.wav"); try Data([0, 1, 2]).write(to: audio)
        for provider in ["volcano", "bailian_cn", "mimo"] {
            var settings = Settings(); settings.provider = provider; settings.prompt = "fixture"; settings.app_context = false
            let request = try Recognition.request(audio: audio, settings: settings, context: "fixture", screenshot: data)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let content = messages[1]["content"] as! [[String: Any]]
            try check(content.filter { $0["type"] as? String == "input_audio" }.count == 1 && content.filter { $0["type"] as? String == "image_url" }.count == 1, "\(provider) 图片音频同一请求")
            let image = content.last!["image_url"] as! [String: String]
            try check(image["url"] == "data:image/jpeg;base64," + data.base64EncodedString(), "\(provider) 提交原压缩字节")
            let instruction = messages[0]["content"] as! String
            try check(instruction.contains("以用户录音为准") && !instruction.contains("用户当前输入环境"), "截图提示词独立于应用标题开关")
            let plain = try Recognition.request(audio: audio, settings: settings, context: "")
            let plainBody = try JSONSerialization.jsonObject(with: plain.httpBody!) as! [String: Any]
            let plainMessages = plainBody["messages"] as! [[String: Any]]
            try check(!(plainMessages[0]["content"] as! String).contains("附图"), "无截图时不追加图片规则")
        }
        var unsupported = Settings(); unsupported.provider = "bailian_cn"; unsupported.providers[unsupported.provider]!.model = "qwen3-omni-flash"
        try check(!Recognition.supportsScreenshot(unsupported), "旧模型不混传图片音频")
        let legacy = HistoryEntry(text: "fixture", error: "", audio: "fixture.wav", model: "fixture")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "screenshot")
        let restored = try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: object))
        try check(restored.screenshot == nil, "兼容无截图的旧历史")
        let file = root.appendingPathComponent("history.json")
        var entries: [HistoryEntry] = []
        for i in 0...HistoryStore.limit {
            var entry = HistoryEntry(text: "fixture", error: "", audio: "\(i).wav", model: "fixture")
            entry.screenshot = "\(i).jpg"; entries.append(entry)
            try data.write(to: root.appendingPathComponent("\(i).jpg"))
            try Data([0]).write(to: root.appendingPathComponent("\(i).wav"))
        }
        try JSONEncoder().encode(entries).write(to: file)
        let store = HistoryStore(file: file, recordings: root)
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(HistoryStore.limit).jpg").path), "淘汰历史同时删除截图")
        var updated = store.items[0]; updated.text = "regenerated"; store.update(updated)
        try check(try Data(contentsOf: store.screenshotURL(updated)!) == data, "重新识别保留原截图字节")
        let unrelated = root.appendingPathComponent("unrelated.jpg"); try data.write(to: unrelated)
        try store.clear()
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("0.jpg").path) && FileManager.default.fileExists(atPath: unrelated.path), "清空只删除关联截图")
        let slow = ScreenshotJob(operation: { try? await Task.sleep(nanoseconds: 300_000_000); return ScreenshotResult(jpeg: data) }, timeout: 0.03)
        let timedOut = await slow.value()
        try check(timedOut.jpeg == nil && timedOut.note?.contains("超时") == true, "截图超时不阻塞提交")
        let canceled = ScreenshotJob(operation: { try? await Task.sleep(nanoseconds: 300_000_000); return ScreenshotResult(jpeg: data) })
        canceled.cancel(); let canceledResult = await canceled.value()
        try check(canceledResult.jpeg == nil, "取消不保留迟到截图")
        let fast = ScreenshotJob(operation: { ScreenshotResult(jpeg: data, source: "window") })
        let ready = await fast.value()
        try check(ready.jpeg == data, "截图早于录音完成时保留结果")
        print("Screenshot checks passed; synthetic data only, no capture/network/input injection")
    }
}
