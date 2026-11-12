import Foundation

struct RecognitionStatistics: Codable {
    var firstTextSeconds: Double?
    var totalSeconds: Double
    var estimatedCNY: Double?
    var pricingNote: String
    var promptTokens: Int?
    var completionTokens: Int?
    var audioTokens: Int?
    var cachedTokens: Int?
    var imageTokens: Int?
    var estimatedImageCNY: Double?
    var imageCostEstimatedFromRule: Bool? = nil
    var fastFallback: Bool? = nil
    var serviceTier: String? = nil
    var thoughtTokens: Int? = nil
    var retried: Bool = false
}

struct RecognitionResult {
    /// 去掉末尾标点之前的文字(“接着说”补标点用);未开去标点时与 text 相同。
    var rawText = ""
    let text: String
    let statistics: RecognitionStatistics
}

enum RecognitionPricing {
    // 人民币/百万 Token，核对日期 2026-10-17。
    // https://help.aliyun.com/zh/model-studio/model-pricing
    // https://mimo.mi.com/docs/en-US/pricing
    // 固化当次估值，不随着日后价目表变化重新计算历史。
    static func statistics(usage: [String: Any]?, settings: Settings, first: Double?, total: Double, serviceTier: String? = nil, hasScreenshot: Bool = false) -> RecognitionStatistics {
        let input = usage?["prompt_tokens"] as? Int
        let output = usage?["completion_tokens"] as? Int
        let details = usage?["prompt_tokens_details"] as? [String: Any] ?? [:]
        let audio = details["audio_tokens"] as? Int
        let cached = details["cached_tokens"] as? Int
        let image = details["image_tokens"] as? Int
        var stats = RecognitionStatistics(firstTextSeconds: first, totalSeconds: total, estimatedCNY: nil,
            pricingNote: "服务未返回完整用量，无法估算费用", promptTokens: input, completionTokens: output,
            audioTokens: audio, cachedTokens: cached)
        stats.serviceTier = serviceTier
        guard let input, let output, input >= 0, output >= 0 else { return stats }
        let model = settings.active.model
        let host = URL(string: settings.active.base_url)?.host ?? ""
        stats.imageTokens = image
        stats.thoughtTokens = usage?["thought_tokens"] as? Int
        var imageRate: Double?
        var cost: Double?
        if settings.provider == "gemini", host == "generativelanguage.googleapis.com", GeminiAPI.models.contains(model) {
            // 官方 Standard 价，美元/百万 Token。按 UTC 日期切换已公布的优惠截止日期。
            // https://ai.google.dev/gemini-api/docs/pricing
            let lite = model == "gemini-3.5-flash-lite"
            let flash = model != "gemini-4-argon"
            let cutoff = ISO8601DateFormatter().date(from: flash ? "2027-01-01T00:00:00Z" : "2026-12-01T00:00:00Z")!
            let multiplier = lite || Date() < cutoff ? 1.0 : 2.0
            let inputRate = (lite ? 0.30 : (flash ? 0.75 : 2.0)) * multiplier * 7
            let outputRate = (lite ? 2.50 : (flash ? 3.75 : 10.0)) * multiplier * 7
            let cacheRate = (lite ? 0.03 : (flash ? 0.075 : 0.1)) * multiplier * 7
            let cache = cached ?? 0
            if cache == 0 { imageRate = inputRate }
            if (0...input).contains(cache) {
                cost = (Double(input-cache)*inputRate + Double(cache)*cacheRate + Double(output)*outputRate) / 1_000_000
            }
            stats.pricingNote = "按 Google Standard 公开价及返回用量估算，含思考 Token；固定汇率 1 美元=7 元，非实时汇率，不扣免费额度。价格核对：2026-10-17。"
        } else if settings.provider == "volcano", host == "ark.cn-beijing.volces.com", Provider.volcanoModels.contains(model) {
            // 火山方舟公开价，2026-10-17；按服务实际返回档位计费。
            // https://docs.volcengine.com/docs/ark/model-pricing
            let rates: (Double, Double, Double)
            switch model {
            case "doubao-seed-2-0-mini-260428": rates = (0.2, 3, 2)
            case "doubao-seed-2-0-lite-260428": rates = (0.6, 9, 3.6)
            default: rates = (0.8, 12, 2.7)
            }
            // 缓存缺少音频拆分、未知档位或超出已核对价格区间时，不猜测费用。
            if let audio, (0...input).contains(audio), (cached ?? 0) == 0,
               ["default", "fast"].contains(serviceTier ?? ""), input <= 32_768 {
                let multiplier = serviceTier == "fast" ? 2.0 : 1.0
                imageRate = rates.0 * multiplier
                cost = (Double(input-audio)*rates.0 + Double(audio)*rates.1 + Double(output)*rates.2) * multiplier / 1_000_000
            }
            stats.pricingNote = "按火山方舟北京公开价及实际返回档位估算，Fast 为常规档的 2 倍；不扣免费额度。价格核对：2026-10-17。"
        } else if settings.provider == "mimo", host == "api.xiaomimimo.com", model == "mimo-v2.6-flash" {
            let cache = cached ?? 0
            if cache == 0 { imageRate = 1 }
            if (0...input).contains(cache) {
                cost = (Double(input-cache) + Double(cache)*0.02 + Double(output)*2) / 1_000_000
            }
            stats.pricingNote = "按 MiMo 国内按量价格估算；不含套餐、赠送额度与优惠。价格核对：2026-10-17。"
        } else if ["bailian", "bailian_cn"].contains(settings.provider),
                  ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"].contains(host) {
            let cn = host == "dashscope.aliyuncs.com"
            if model == "qwen3.8-omni-flash" {
                let cache = cached ?? 0
                if cache == 0 { imageRate = cn ? 0.8 : 1.094 }
                if (0...input).contains(cache) {
                    cost = (Double(input-cache)*(cn ? 0.8 : 1.094) + Double(cache)*(cn ? 0.1 : 0.117) + Double(output)*(cn ? 2.7 : 3.427)) / 1_000_000
                }
            } else if let audio, (0...input).contains(audio) {
                var rates: (Double, Double, Double)?
                switch model {
                case "qwen3.5-omni-flash", "qwen3.5-omni-flash-2026-03-15": rates = cn ? (2.2,18,13.3) : (3,22.48,16.49)
                case "qwen3-omni-flash": rates = cn ? (1.8,15.8,12.7) : (3.156,27.962,22.458)
                default: break
                }
                if let r = rates { imageRate = r.0; cost = (Double(input-audio)*r.0 + Double(audio)*r.1 + Double(output)*r.2) / 1_000_000 }
            }
            stats.pricingNote = "按百炼\(cn ? "北京" : "新加坡")人民币公开单价及实际 Token 用量估算；不扣除免费额度或优惠。价格核对：2026-10-17。"
        } else { stats.pricingNote = "当前模型或接口没有已核对的价目表，无法估算费用" }
        stats.estimatedCNY = cost
        // 缓存未拆到图片模态时不把全部图片按未缓存价格算作实付占比。
        if let image, image >= 0, image <= input - (audio ?? 0), let imageRate, cost != nil {
            stats.estimatedImageCNY = Double(image) * imageRate / 1_000_000
        }
        if cost == nil { stats.pricingNote = "用量明细或模型价格不完整，无法估算费用" }
        if settings.provider == "volcano", host == "ark.cn-beijing.volces.com" {
            stats = addingSeedImageEstimate(stats, model: model, hasScreenshot: hasScreenshot)
        }
        return stats
    }

    /// 当前单图请求未指定 detail，Seed 2.0+ 默认为 high，固定 1280 Token。
    /// https://docs.volcengine.com/docs/ark/image-understanding?lang=zh
    /// 只补图片估值，不冒充服务返回的 imageTokens，也不改当次总费用。
    static func addingSeedImageEstimate(_ stats: RecognitionStatistics, model: String, hasScreenshot: Bool) -> RecognitionStatistics {
        guard hasScreenshot, stats.imageTokens == nil, stats.estimatedImageCNY == nil,
              stats.cachedTokens == 0, let input = stats.promptTokens, input <= 32_768,
              let audio = stats.audioTokens, audio >= 0, input - audio >= 1280,
              let total = stats.estimatedCNY, total > 0,
              let tier = stats.serviceTier, ["default", "fast"].contains(tier) else { return stats }
        let rate: Double
        switch model {
        case "doubao-seed-2-1-lite-260915": rate = 0.8
        case "doubao-seed-2-0-lite-260428": rate = 0.6
        case "doubao-seed-2-0-mini-260428": rate = 0.2
        default: return stats
        }
        let cost = 1280 * rate * (tier == "fast" ? 2.0 : 1.0) / 1_000_000
        guard cost <= total else { return stats }
        var result = stats
        result.estimatedImageCNY = cost
        result.imageCostEstimatedFromRule = true
        return result
    }
}
