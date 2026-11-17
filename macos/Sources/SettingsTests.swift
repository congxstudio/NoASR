import Foundation

/// 临时配置自检，不申请权限、不修改自启项、不使用真实密钥或网络。
enum SettingsTests {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw VoiceError(message: message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        let fixtures: [[String: Any]?] = [nil, [:], ["appearance": "dark"]]
        for object in fixtures {
            if let object { try JSONSerialization.data(withJSONObject: object).write(to: file) }
            let settings = Settings.load(file: file, environment: [:])
            try check(settings.provider == "volcano" && settings.volcano_fast, "默认火山及 Fast")
            try check(settings.autostart && settings.strip_trailing_punct, "默认自启与去掉末尾标点")
            try check(!settings.screenshot_tool_enabled && settings.screenshot_markup, "截图工具默认关闭、标注默认开启")
            try check(settings.sound_style == "bubble", "默认气泡提示音")
            try check(settings.providers.values.allSatisfy { $0.api_key.isEmpty }, "测试隔离真实密钥")
        }
        try check(Provider.order == ["volcano", "bailian_cn", "mimo", "gemini"] && Provider.defaults["bailian"] == nil, "服务顺序与移除新加坡")
        let saved: [String: Any] = ["provider": "mimo", "volcano_fast": false, "autostart": false,
                                    "strip_trailing_punct": false, "screenshot_tool_enabled": true,
                                    "screenshot_markup": false, "sound_style": "bell"]
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let restored = Settings.load(file: file, environment: [:])
        try check(restored.provider == "mimo" && !restored.volcano_fast && !restored.autostart && !restored.strip_trailing_punct,
                  "保留已保存的服务、Fast、自启和标点选择")
        try check(restored.screenshot_tool_enabled && !restored.screenshot_markup && restored.sound_style == "bell", "保留截图和音色选择")
        try JSONSerialization.data(withJSONObject: ["provider": "bailian", "providers": ["bailian": ["api_key": "fixture-only"]]]).write(to: file)
        let migrated = Settings.load(file: file, environment: [:])
        try check(migrated.provider == "volcano" && migrated.providers["bailian"] == nil && migrated.active.api_key.isEmpty, "旧节点密钥不迁往其他服务")
        try FileManager.default.removeItem(at: file)
        let fromEnvironment = Settings.load(file: file, environment: ["ARK_API_KEY": "fixture-env-only"])
        try check(fromEnvironment.active.api_key == "fixture-env-only", "无配置文件时读取环境变量")
    }
}
