import Foundation

/// Google 原生 SSE 接口；只发布正文，思考用量仍计入费用。
enum GeminiAPI {
    static let models = ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-4-argon"]

    static func thinkingLevel(for model: String) -> String {
        ["gemini-3.5-flash-lite", "gemini-3.6-flash"].contains(model) ? "MINIMAL" : "LOW"
    }

    static func request(provider: Provider, prompt: String, audio: Data, mime: String, screenshot: Data?) throws -> URLRequest {
        guard models.contains(provider.model), let base = URL(string: provider.base_url),
              base.scheme == "https", base.host == "generativelanguage.googleapis.com" else {
            throw VoiceError(message: "Gemini 模型或官方接口地址无效")
        }
        var parts: [[String: Any]] = [
            ["inlineData": ["mimeType": mime, "data": audio.base64EncodedString()]],
            ["text": "请按系统指令处理这段录音。没有清晰说话内容时什么都不要输出。"]
        ]
        if let screenshot { parts.append(["inlineData": ["mimeType": "image/jpeg", "data": screenshot.base64EncodedString()]]) }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": prompt]]],
            "contents": [["role": "user", "parts": parts]],
            // 各型号使用官方支持的最低推理等级。
            "generationConfig": ["thinkingConfig": ["thinkingLevel": thinkingLevel(for: provider.model), "includeThoughts": false]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count < 20_000_000 else { throw VoiceError(message: "本次录音和截图超过 Gemini 单次上传限制，请缩短录音") }
        var components = URLComponents(url: base.appendingPathComponent("models/\(provider.model):streamGenerateContent"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(provider.api_key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        Paths.log("请求: provider=gemini model=\(provider.model) audio=\(audio.count)B JSON=\(data.count)B thinking=\(thinkingLevel(for: provider.model))")
        return request
    }

    struct Chunk {
        var text = ""
        var usage: [String: Any]?
        var finished = false
    }
    static func chunk(_ json: [String: Any]) throws -> Chunk {
        if json["error"] != nil { throw VoiceError(message: "Gemini 流式请求失败，请检查服务额度或稍后重试") }
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw VoiceError(message: "Gemini 未接受本次内容，请查看历史记录后重试")
        }
        var result = Chunk()
        if let usage = json["usageMetadata"] as? [String: Any] {
            var normalized: [String: Any] = [:]
            if let input = usage["promptTokenCount"] as? Int { normalized["prompt_tokens"] = input }
            if let output = usage["candidatesTokenCount"] as? Int {
                normalized["completion_tokens"] = output + (usage["thoughtsTokenCount"] as? Int ?? 0)
            }
            normalized["thought_tokens"] = usage["thoughtsTokenCount"] as? Int
            var details: [String: Any] = ["cached_tokens": usage["cachedContentTokenCount"] as? Int ?? 0]
            for item in usage["promptTokensDetails"] as? [[String: Any]] ?? [] {
                switch item["modality"] as? String {
                case "AUDIO": details["audio_tokens"] = item["tokenCount"]
                case "IMAGE": details["image_tokens"] = item["tokenCount"]
                default: break
                }
            }
            normalized["prompt_tokens_details"] = details
            result.usage = normalized
        }
        if let candidate = (json["candidates"] as? [[String: Any]])?.first {
            if let reason = candidate["finishReason"] as? String {
                guard reason == "STOP" else { throw VoiceError(message: "Gemini 未完整生成结果（\(reason)），请重试") }
                result.finished = true
            }
            let content = candidate["content"] as? [String: Any] ?? [:]
            result.text = (content["parts"] as? [[String: Any]] ?? []).filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        }
        return result
    }
}
