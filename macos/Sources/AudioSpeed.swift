import Foundation
import AVFoundation

/// 离线变速不变调；不连接输出设备，不播放到扬声器。
enum AudioSpeed {
    static let rates: [Double] = [1.25, 1.5, 1.75, 2.0]
    static func prepare(_ input: URL, rate: Double) throws -> PreparedAudio {
        let started = Date()
        guard rates.contains(rate) else { throw VoiceError(message: "不支持的录音加速倍率") }
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        guard format.channelCount == 1, format.sampleRate == 16000 else { throw VoiceError(message: "加速录音格式不正确") }
        guard let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw VoiceError(message: "无法读取加速录音") }
        try file.read(into: original)
        guard let samples = original.floatChannelData?[0] else { throw VoiceError(message: "无法读取音频采样") }
        let integers = (0..<Int(original.frameLength)).map { Int16(max(-32768, min(32767, Double(samples[$0]) * 32768))) }
        let range = AudioPreparation.trimmedRange(integers)
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)), let output = trimmed.floatChannelData?[0] else { throw VoiceError(message: "无法创建音频缓冲区") }
        trimmed.frameLength = AVAudioFrameCount(range.count)
        output.update(from: samples.advanced(by: range.lowerBound), count: range.count)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate); pitch.pitch = 0
        engine.attach(player); engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        player.scheduleBuffer(trimmed, at: nil)
        try engine.start(); player.play()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw VoiceError(message: "无法创建加速缓冲区")
        }
        let expected = Int(ceil(Double(range.count) / rate))
        var pcm: [Int16] = []; pcm.reserveCapacity(expected)
        var retries = 0
        while pcm.count < expected {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(4096, expected - pcm.count))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { throw VoiceError(message: "加速音频输出为空") }
                for index in 0..<Int(buffer.frameLength) {
                    pcm.append(Int16(max(-32768, min(32767, (Double(samples[index]) * 32768).rounded()))))
                }
                retries = 0
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                retries += 1
                guard retries < 100 else { throw VoiceError(message: "录音加速处理未能完成") }
            case .error: throw VoiceError(message: "录音加速处理失败")
            @unknown default: throw VoiceError(message: "未知录音加速状态")
            }
        }
        let data = try MP3Encoder().encode(pcm)
        try Task.checkCancellation()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("voice-speed-\(UUID().uuidString).mp3")
        try data.write(to: target, options: .atomic)
        return PreparedAudio(url: target, rawBytes: (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                             bytes: data.count, rawSeconds: Double(range.count) / 16000, seconds: Double(pcm.count) / 16000,
                             preparationMS: Int(Date().timeIntervalSince(started) * 1000))
    }
}
