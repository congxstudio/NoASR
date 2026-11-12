import AppKit
import AVFoundation

/// 程序内合成的短提示音,几种音色可在设置中切换,不依赖系统 Tink / Pop。
enum Cues {
    /// 顺序即设置下拉框的顺序;第一项为默认。
    static let styles: [(key: String, title: String)] = [
        ("bell", "铃声"), ("marimba", "木琴"), ("bubble", "气泡"), ("chime", "双音"), ("coin", "金币")
    ]
    static func validStyle(_ key: String?) -> String { styles.contains { $0.key == key } ? key! : styles[0].key }

    private static func envelope(_ x: Double, attack: Double, decay: Double) -> Double {
        x < 0 ? 0 : min(1, x / attack) * exp(-x / decay)
    }
    private static func marimba(_ x: Double, _ frequency: Double) -> Double {
        envelope(x, attack: 0.003, decay: 0.07) * sin(2 * .pi * frequency * x)
            + 0.25 * envelope(x, attack: 0.002, decay: 0.02) * sin(2 * .pi * 4 * frequency * x)
    }
    private static func bubble(_ x: Double, from f0: Double, to f1: Double) -> Double {
        guard x >= 0, x <= 0.16 else { return 0 }
        let slide = 0.07, k = log(f1 / f0) / slide
        let phase = f0 * (exp(k * min(x, slide)) - 1) / k + (x <= slide ? 0 : f1 * (x - slide))
        return envelope(x, attack: 0.004, decay: 0.045) * sin(2 * .pi * phase)
    }
    private static func bell(_ x: Double, _ frequency: Double) -> Double {
        guard x >= 0 else { return 0 }
        // 调制深度随时间衰减,起音带一点金属感,尾音变纯。
        let depth = 1.6 * exp(-x / 0.08)
        return envelope(x, attack: 0.004, decay: 0.16) * sin(2 * .pi * frequency * x + depth * sin(2 * .pi * frequency * 1.41 * x))
    }
    /// 带限方波(奇次谐波叠加),红白机那种芯片音。
    private static func square(_ x: Double, _ frequency: Double, rate: Double = 24000) -> Double {
        var value = 0.0; var k = 1.0
        while frequency * k < rate / 2 { value += sin(2 * .pi * frequency * k * x) / k; k += 2 }
        return value * 4 / .pi
    }
    /// 超级玛丽金币:B5 短促一下,接着 E6 拖长渐弱。
    private static func coin(_ x: Double, from first: Double, to second: Double, hold: Double) -> Double {
        guard x >= 0 else { return 0 }
        if x < hold { return 0.9 * min(1, x / 0.002) * square(x, first) }
        let t = x - hold
        return min(1, t / 0.002) * exp(-t / 0.18) * square(x, second)
    }
    private static func chime(_ x: Double, _ frequency: Double) -> Double {
        guard x >= 0 else { return 0 }
        return min(1, x / 0.006) * exp(-x * 9) * sin(2 * .pi * frequency * x)
    }
    /// 返回时长与波形函数;开始音偏高、结束音偏低。
    private static func voice(style: String, start: Bool) -> (duration: Double, wave: (Double) -> Double) {
        let g5 = 783.99, b5 = 987.77, c6 = 1046.5, e6 = 1318.5
        switch style {
        case "marimba":
            let (first, second) = start ? (g5, c6) : (c6, g5)
            return (0.32, { t in marimba(t, first) + 0.8 * marimba(t - 0.07, second) })
        case "bubble":
            return (0.20, { t in start ? bubble(t, from: 500, to: 1000) : bubble(t, from: 900, to: 450) })
        case "chime":
            let (first, second) = start ? (660.0, 990.0) : (880.0, 587.33)
            return (start ? 0.30 : 0.27, { t in chime(t, first) + 0.8 * chime(t - 0.055, second) })
        case "coin":
            // 开始是金币原调 B5→E6;结束反过来 E6→B5,短一点。
            return start ? (0.55, { t in coin(t, from: b5, to: e6, hold: 0.08) }) : (0.40, { t in coin(t, from: e6, to: b5, hold: 0.07) })
        default:
            return (0.40, { t in bell(t, start ? e6 : b5) })
        }
    }
    static func audio(start: Bool, style: String = styles[0].key) -> Data {
        let rate = 24000
        let lead = 0.03
        let (duration, wave) = voice(style: validStyle(style), start: start)
        let count = Int(Double(rate) * (duration + lead))
        var values = (0..<count).map { i -> Double in
            let t = Double(i) / Double(rate) - lead
            return wave(t) * min(1, max(0, (duration - t) / 0.03))
        }
        // 各音色峰值统一到 0.7,切换音色时响度一致。
        let peak = values.map(abs).max() ?? 0
        if peak > 1e-9 { values = values.map { $0 * 0.7 / peak } }
        var pcm = Data(capacity: count * 2)
        for value in values {
            var little = Int16(max(-1, min(1, value)) * 32767).littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func text(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    // 程序内预加载播放:麦克风就绪后立刻响,不再经外部进程(启动要几百毫秒)。不持有录音设备。
    private static var players: [String: AVAudioPlayer] = [:]
    private static func player(style: String, start: Bool) -> AVAudioPlayer? {
        let key = "\(style)/\(start)"
        if let player = players[key] { return player }
        guard let player = try? AVAudioPlayer(data: audio(start: start, style: style)) else { Paths.log("提示音准备失败"); return nil }
        player.prepareToPlay(); players[key] = player
        return player
    }
    /// 启动时预加载当前音色,首次播放不卡。
    static func preload(style: String) { _ = player(style: validStyle(style), start: true); _ = player(style: validStyle(style), start: false) }
    private static var generation = 0
    static func cancel() {
        generation += 1
        for player in players.values where player.isPlaying { player.stop(); player.currentTime = 0; player.prepareToPlay() }
    }
    static func cleanup() { cancel() }
    private static func play(start: Bool, style: String, volume: Double, delay: Double, completion: (() -> Void)? = nil) {
        cancel()
        let token = generation
        let run = {
            guard token == generation, let player = player(style: validStyle(style), start: start) else { return }
            player.volume = Float(min(1, max(0, volume))); player.currentTime = 0
            let played = player.play()
            Paths.log("提示音: \(start ? "开始" : "结束"),音色=\(validStyle(style)),音量=\(Int(min(1,max(0,volume))*100))%,播放=\(played)")
            guard played, let completion else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration) { if token == generation { completion() } }
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run) } else { run() }
    }
    static func preview(volume: Double, style: String) {
        play(start: true, style: style, volume: volume, delay: 0) {
            play(start: false, style: style, volume: volume, delay: 0.12)
        }
    }
    static func playStart(volume: Double = 0.85, style: String, delay: Double = 0) { play(start: true, style: style, volume: volume, delay: delay) }
    static func playStop(volume: Double = 0.85, style: String, delay: Double = 0) { play(start: false, style: style, volume: volume, delay: delay) }
}
