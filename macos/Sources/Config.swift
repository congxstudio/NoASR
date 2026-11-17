import Foundation

struct Provider: Codable {
    var api_key = ""
    var base_url: String
    var model: String
    static let volcanoModels = ["doubao-seed-2-1-lite-260915", "doubao-seed-2-0-lite-260428", "doubao-seed-2-0-mini-260428"]
    static func modelTitle(_ id: String) -> String {
        switch id {
        case "doubao-seed-2-1-lite-260915": return "Seed 2.1 Lite"
        case "doubao-seed-2-0-lite-260428": return "Seed 2.0 Lite"
        case "doubao-seed-2-0-mini-260428": return "Seed 2.0 Mini"
        default: return id
        }
    }
    static let order = ["volcano", "bailian_cn", "mimo", "gemini"]
    static let titles = ["volcano": "火山方舟", "bailian_cn": "百炼·北京", "mimo": "小米 MiMo", "gemini": "Gemini"]
    static let defaults = [
        "bailian_cn": Provider(base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.5-omni-flash"),
        "mimo": Provider(base_url: "https://api.xiaomimimo.com/v1", model: "mimo-v2.6-flash"),
        "volcano": Provider(base_url: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-seed-2-1-lite-260915"),
        "gemini": Provider(base_url: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-3.8-flash")
    ]
}

struct Settings: Codable {
    var appearance = "system"
    var provider = "volcano"
    var providers = Provider.defaults
    var volcano_fast = true
    var screenshot_tool_enabled = false
    var screenshot_markup = true
    var screenshot_hotkey = "command+shift+a"
    var screenshot_hotkey_secondary = "option+shift+s"
    var dictionary_hotkey = "control+option+d"   // 选中文字加入词典
    var dictionary_learn = "ask"                 // ask 每次询问 / auto 第 2 次自动记住 / off
    var hotkey = "right option"
    var mode = "both"
    var device = ""
    var device_uid = ""
    var mouse_longpress = true
    var overlay_position = "window"
    static let legacyPrompt = "请把这段语音逐字转写为文字,只输出转写结果,不要解释。保留原语言,自动补全标点。"
    var prompt = "你是用户的表达助手，录音是用户的原始说话内容，请理解说话内容后，帮助他进行流畅表达，请直接输出优化后的内容结果，其他信息一概不要输出，比如你的思考过程、你对结果的补充描述等等。\n\n背景（这段不要输出）：录音中可能包含口头禅、语气词重复、停顿与思考过程，语句也可能断断续续。请在不改变原意的前提下，将内容整理为通顺、连贯、不废话、符合表达习惯的语句，同时保留必要的语义完整性与自然节奏，避免过度删减导致信息丢失。根据内容自然分段，不同话题或要点之间空一行；短内容不必强行分段。\"呃、嗯、啊、那个、这个、然后\"这类语气词和口头禅一律删掉，重复的词只保留一次\n\n硬性约束（违反比不整理更糟）：\n1. 不得改变肯定/否定。原话说\"是、要、能、有\"，就不能写成\"不是、不要、不能、没有\"；反之同理。\n2. 不得改变数量、程度、范围、时间和主语。\n3. 不得替用户推断结论；拿不准的地方原样保留，宁可口语化。\n4. 只允许：删语气词、去重复、补标点、顺句子。不允许换词、不允许改写立场。"
    var strip_trailing_punct = true
    var app_context = true
    var screenshot_consent = false
    var window_screenshot = false
    var screenshot_dual_test = false
    var history_enabled = true
    var history_limit = 100 // 0 表示永久
    static let historyLimits = [1, 3, 10, 50, 100, 0]
    var audio_speed_test = false
    var audio_speed_rate = 1.25
    var screenshot_authorization_pending = false
    var sound = true
    var sound_volume = 0.85
    var sound_style = "bubble"
    var autostart = true
    var active: Provider { providers[provider] ?? Provider.defaults["volcano"]! }

    static func load(file: URL = Paths.config, environment: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
        // 只迁移已有的服务配置与密钥;原生版交互默认支持短按和长按。
        let data = (try? Data(contentsOf: file)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var value = Settings()
        if let appearance = object["appearance"] as? String, ["system", "light", "dark"].contains(appearance) { value.appearance = appearance }
        if let name = object["provider"] as? String, Provider.defaults[name] != nil { value.provider = name }
        if let providers = object["providers"] as? [String: [String: String]] {
            for (key, fields) in providers where value.providers[key] != nil {
                if let keyValue = fields["api_key"] { value.providers[key]!.api_key = keyValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let url = fields["base_url"] { value.providers[key]!.base_url = url }
                if let model = fields["model"] { value.providers[key]!.model = model }
            }
        }
        value.volcano_fast = object["volcano_fast"] as? Bool ?? true
        value.screenshot_tool_enabled = object["screenshot_tool_enabled"] as? Bool ?? false
        value.screenshot_markup = object["screenshot_markup"] as? Bool ?? true
        value.autostart = object["autostart"] as? Bool ?? true
        value.screenshot_hotkey = object["screenshot_hotkey"] as? String ?? value.screenshot_hotkey
        value.screenshot_hotkey_secondary = object["screenshot_hotkey_secondary"] as? String ?? (value.screenshot_hotkey == "option+shift+s" ? "command+shift+a" : "option+shift+s")
        value.dictionary_hotkey = object["dictionary_hotkey"] as? String ?? value.dictionary_hotkey
        value.dictionary_learn = ["ask", "auto", "off"].contains(object["dictionary_learn"] as? String ?? "") ? object["dictionary_learn"] as! String : "ask"
        value.hotkey = object["hotkey"] as? String ?? value.hotkey
        value.device = object["device"] as? String ?? ""
        value.device_uid = object["device_uid"] as? String ?? ""
        value.mouse_longpress = object["mouse_longpress"] as? Bool ?? true
        if let position = object["overlay_position"] as? String, ["bottom", "cursor", "window"].contains(position) { value.overlay_position = position }
        // 旧版默认提示词(逐字转写)自动换成新的默认;用户自己改过的保持不变。
        if let saved = object["prompt"] as? String, saved != Settings.legacyPrompt { value.prompt = saved }
        value.sound = object["sound"] as? Bool ?? true
        value.sound_volume = min(1, max(0, object["sound_volume"] as? Double ?? 0.85))
        value.sound_style = Cues.validStyle(object["sound_style"] as? String)
        value.app_context = object["app_context"] as? Bool ?? true
        value.screenshot_consent = object["screenshot_consent"] as? Bool ?? false
        value.window_screenshot = object["window_screenshot"] as? Bool ?? false
        // 已移除开发者测试入口；旧配置即使开启也不再发送额外测试请求。
        value.screenshot_dual_test = false
        value.history_enabled = object["history_enabled"] as? Bool ?? true
        let historyLimit = object["history_limit"] as? Int ?? 100
        value.history_limit = Settings.historyLimits.contains(historyLimit) ? historyLimit : 100
        value.audio_speed_test = false
        let rate = object["audio_speed_rate"] as? Double ?? 1.25
        value.audio_speed_rate = AudioSpeed.rates.contains(rate) ? rate : 1.25
        value.screenshot_authorization_pending = object["screenshot_authorization_pending"] as? Bool ?? false
        value.strip_trailing_punct = object["strip_trailing_punct"] as? Bool ?? true
        if object["native_version"] != nil { value.mode = object["mode"] as? String ?? "both" }
        if value.providers["bailian_cn"]!.api_key.isEmpty { value.providers["bailian_cn"]!.api_key = environment["DASHSCOPE_CN_API_KEY"] ?? "" }
        if value.providers["mimo"]!.api_key.isEmpty { value.providers["mimo"]!.api_key = environment["MIMO_API_KEY"] ?? "" }
        if value.providers["gemini"]!.api_key.isEmpty { value.providers["gemini"]!.api_key = environment["GEMINI_API_KEY"] ?? "" }
        if value.providers["volcano"]!.api_key.isEmpty { value.providers["volcano"]!.api_key = environment["ARK_API_KEY"] ?? "" }
        return value
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["native_version"] = 1
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: Paths.config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
    }
}

enum Paths {
    static let isDevelopment = Bundle.main.bundleIdentifier == "com.daiwen.voice-input.development"
    static let data: URL = {
        let directory = isDevelopment ? "OneMoreDevelopment" : "DaiwenVoiceInput"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var config: URL { data.appendingPathComponent("config.json") }
    static var dictionary: URL { data.appendingPathComponent("dictionary.json") }
    static var history: URL { data.appendingPathComponent("native-history.json") }
    static var recordings: URL {
        let url = data.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func log(_ message: String) {
        let url = data.appendingPathComponent("native.log")
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 512 * 1024 {
            let previous = data.appendingPathComponent("native.log.1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

struct ScreenshotComparison: Codable {
    var speedRate: Double? = nil
    var preparationMS: Int? = nil
    var originalSeconds: Double? = nil
    var acceleratedSeconds: Double? = nil
    var id = UUID().uuidString
    var status = "running"
    var text = ""
    var error = ""
    var model: String
    var provider: String
    var statistics: RecognitionStatistics? = nil
}

struct HistoryEntry: Codable {
    var id = UUID().uuidString
    var date = Date()
    var text: String
    var error: String
    var audio: String
    var model: String
    var provider: String? = nil
    var context: String? = nil
    var screenshot: String? = nil
    var screenshotSource: String? = nil
    var screenshotNote: String? = nil
    var statistics: RecognitionStatistics? = nil
    var screenshotComparison: ScreenshotComparison? = nil
    var audioSpeedComparison: ScreenshotComparison? = nil
}

final class HistoryStore {
    private(set) var items: [HistoryEntry]
    private let file: URL
    private let recordings: URL
    private(set) var enabled: Bool
    private(set) var retention: Int
    var onError: ((String) -> Void)?
    init(file: URL = Paths.history, recordings: URL = Paths.recordings, retention: Int = HistoryStore.limit, enabled: Bool = true) {
        self.file = file; self.recordings = recordings
        self.retention = retention; self.enabled = enabled
        items = (try? JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: file))) ?? []
        for index in items.indices where items[index].screenshotComparison?.status == "running" {
            items[index].screenshotComparison?.status = "failed"
            items[index].screenshotComparison?.error = "应用已退出，对比请求未完成"
        }
        for index in items.indices where items[index].audioSpeedComparison?.status == "running" {
            items[index].audioSpeedComparison?.status = "failed"
            items[index].audioSpeedComparison?.error = "应用已退出，对比请求未完成"
        }
        persist()
    }
    func add(_ entry: HistoryEntry) {
        guard enabled else { return }
        items.removeAll { $0.id == entry.id }
        items.insert(entry, at: 0); persist()
    }
    func update(_ entry: HistoryEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[index] = entry; persist()
    }
    /// 主请求与对比请求独立完成，只合并各自字段，避免后完成的一路覆盖另一路。
    func updatePrimary(_ entry: HistoryEntry) {
        guard let current = items.first(where: { $0.id == entry.id }) else { return }
        var merged = entry
        if current.screenshotComparison?.id == entry.screenshotComparison?.id {
            merged.screenshotComparison = current.screenshotComparison
        }
        if current.audioSpeedComparison?.id == entry.audioSpeedComparison?.id {
            merged.audioSpeedComparison = current.audioSpeedComparison
        }
        update(merged)
    }
    func updateSpeedComparison(entryID: String, comparison: ScreenshotComparison) {
        guard var current = items.first(where: { $0.id == entryID }), current.audioSpeedComparison?.id == comparison.id else { return }
        current.audioSpeedComparison = comparison
        update(current)
    }
    func updateComparison(entryID: String, comparison: ScreenshotComparison) {
        guard var current = items.first(where: { $0.id == entryID }),
              current.screenshotComparison?.id == comparison.id else { return }
        current.screenshotComparison = comparison
        update(current)
    }
    func audioURL(_ entry: HistoryEntry) -> URL {
        recordings.appendingPathComponent(URL(fileURLWithPath: entry.audio).lastPathComponent)
    }
    func screenshotURL(_ entry: HistoryEntry) -> URL? {
        guard let name = entry.screenshot, !name.isEmpty else { return nil }
        return recordings.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }
    func clear() throws {
        for entry in items where !entry.audio.isEmpty {
            let url = audioURL(entry)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        for entry in items {
            if let url = screenshotURL(entry), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        // 同时清理旧版本意外留下的无索引录音/截图，仅限本应用UUID命名的媒体。
        if FileManager.default.fileExists(atPath: recordings.path) {
            for url in try FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil)
                where UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil && ["mp3", "wav", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try JSONEncoder().encode([HistoryEntry]()).write(to: file, options: .atomic)
        items.removeAll()
    }
    static let limit = 100
    func configure(enabled: Bool, retention: Int) throws {
        guard Settings.historyLimits.contains(retention) else { throw VoiceError(message: "无效的历史保留数量") }
        let oldEnabled = self.enabled, oldRetention = self.retention
        self.enabled = enabled; self.retention = retention
        do { try prune() }
        catch { self.enabled = oldEnabled; self.retention = oldRetention; throw error }
    }
    private func prune() throws {
        if !enabled { try clear(); return }
        let count = enabled ? (retention == 0 ? items.count : retention) : 0
        let retained = Array(items.prefix(count))
        let keptAudio = Set(retained.map(\.audio))
        let keptImages = Set(retained.compactMap(\.screenshot))
        // 删除失败保留记录索引，下次持久化重试，不能静默丢掉待删除文件的位置。
        for old in items.dropFirst(count) {
            if !old.audio.isEmpty && !keptAudio.contains(old.audio) {
                let url = audioURL(old)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            if let name = old.screenshot, !keptImages.contains(name), let url = screenshotURL(old), FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try JSONEncoder().encode(retained).write(to: file, options: .atomic)
        items = retained
    }
    private func persist() {
        do { try prune() }
        catch { Paths.log("历史记录保存或清理失败"); onError?("历史记录清理失败，请检查磁盘权限或空间") }
    }

}

struct VoiceError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}


/// 个人词典:用户常用的专有名词、人名、英文短语;识别时加进提示词让模型优先用这些写法。
struct DictionaryTerm: Codable, Equatable {
    var text: String
    var source = "manual"      // manual / hotkey / correction
    var added = Date()
    var app = ""               // 添加时的前台应用(bundle id),按需加载用
    var appName = ""
    var lastHit: Date? = nil   // 最近一次出现在识别结果里
}
struct Dictionary: Codable {
    var items: [DictionaryTerm] = []
    var terms: [String] { items.map(\.text) }
    static var cached: Dictionary?
    static func load() -> Dictionary {
        if let cached { return cached }
        let value = (try? JSONDecoder().decode(Dictionary.self, from: Data(contentsOf: Paths.dictionary))) ?? Dictionary()
        cached = value; return value
    }
    func save() {
        Dictionary.cached = self
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Paths.dictionary, options: .atomic)
    }
    /// 把一段输入拆成词条:逗号/顿号/分号/换行分隔,保留“Claude Code”这类带空格的英文短语。
    static func split(_ input: String) -> [String] {
        input.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n\r\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 40 }
    }
    /// 加入词条,自动去重(英文不分大小写,保留先加的写法)。返回 (新加的, 已存在的)。
    @discardableResult
    mutating func add(_ input: String, source: String = "manual", app: String = "", appName: String = "") -> (added: [String], duplicates: [String]) {
        var added: [String] = [], duplicates: [String] = []
        for term in Dictionary.split(input) {
            if items.contains(where: { $0.text.lowercased() == term.lowercased() }) { duplicates.append(term); continue }
            items.append(DictionaryTerm(text: term, source: source, app: app, appName: appName)); added.append(term)
        }
        return (added, duplicates)
    }
    func contains(_ term: String) -> Bool { items.contains { $0.text.lowercased() == term.lowercased() } }
    /// 识别结果里出现的词条记一次命中(按需加载的依据)。
    mutating func markHits(in text: String) {
        let lower = text.lowercased(); var changed = false
        for index in items.indices where lower.contains(items[index].text.lowercased()) { items[index].lastHit = Date(); changed = true }
        if changed { save() }
    }
    mutating func remove(_ term: String) { items.removeAll { $0.text == term } }
    /// 被用户忽略过的纠正(词对),忽略 2 次后不再问;"seen:" 前缀记自动模式下见过的次数。
    var ignored: [String: Int] = [:]
}
