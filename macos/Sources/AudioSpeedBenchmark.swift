import Foundation

/// 仅通过显式命令行参数启动，真实付费请求；正文写入用户对比报告，不写诊断日志。
enum AudioSpeedBenchmark {
    struct Sample: Codable {
        let entryID: String
        let model: String
        let provider: String
        let originalText: String
        let originalStatistics: RecognitionStatistics?
        var acceleratedText: String?
        var acceleratedStatistics: RecognitionStatistics?
        var preparationMS: Int?
        var originalSeconds: Double?
        var acceleratedSeconds: Double?
        var error: String?
    }
    static func run(output: URL) async throws {
        let history = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: Paths.history))
        let base = Settings.load()
        var selected: [HistoryEntry] = []
        for provider in ["bailian", "bailian_cn"] {
            if let entry = history.filter({ $0.provider == provider && !$0.text.isEmpty && $0.statistics?.estimatedCNY != nil })
                .sorted(by: { $0.text.count > $1.text.count }).first { selected.append(entry) }
        }
        var samples: [Sample] = []
        for entry in selected {
            var sample = Sample(entryID: entry.id, model: entry.model, provider: entry.provider!, originalText: entry.text, originalStatistics: entry.statistics)
            var temporary: URL?
            do {
                var config = base
                config.provider = entry.provider!
                guard var provider = config.providers[config.provider], !provider.api_key.isEmpty else { throw VoiceError(message: "缺少对应服务商的本地密钥") }
                provider.model = entry.model; config.providers[config.provider] = provider
                let audio = Paths.recordings.appendingPathComponent(URL(fileURLWithPath: entry.audio).lastPathComponent)
                let image = try entry.screenshot.map { try Data(contentsOf: Paths.recordings.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent)) }
                let origin = ProcessInfo.processInfo.systemUptime
                let prepared = try AudioSpeed.prepare(audio, rate: 2)
                temporary = prepared.url
                sample.preparationMS = prepared.preparationMS; sample.originalSeconds = prepared.rawSeconds; sample.acceleratedSeconds = prepared.seconds
                let result = try await Recognition.transcribeDetailed(audio: prepared.url, settings: config, context: entry.context ?? "", screenshot: image, timingOrigin: origin)
                sample.acceleratedText = result.text; sample.acceleratedStatistics = result.statistics
                print("完成 \(entry.provider!)：变速\(prepared.preparationMS)ms，原音频\(String(format: "%.1f", prepared.rawSeconds))s，总耗时\(String(format: "%.2f", result.statistics.totalSeconds))s")
            } catch { sample.error = error.localizedDescription; print("对比失败：\(entry.provider!)") }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            samples.append(sample)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        }
    }
}
