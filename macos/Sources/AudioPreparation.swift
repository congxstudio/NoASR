import Foundation
import AVFoundation
import Darwin

struct PreparedAudio: Sendable {
    let url: URL
    let rawBytes: Int
    let bytes: Int
    let rawSeconds: Double
    let seconds: Double
    let preparationMS: Int
}

final class MP3Encoder {
    private let library: UnsafeMutableRawPointer
    typealias Init = @convention(c) () -> OpaquePointer?
    typealias SetInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias Params = @convention(c) (OpaquePointer?) -> Int32
    typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Int16>?, UnsafePointer<Int16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    typealias Flush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    init() throws {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libmp3lame.0.dylib").path
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw VoiceError(message:"MP3 编码库无法加载") }
        self.library = library
    }
    deinit { dlclose(library) }
    private func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(library,name) else { throw VoiceError(message:"MP3 编码接口缺失") }
        return unsafeBitCast(pointer,to:T.self)
    }
    func encode(_ pcm: [Int16]) throws -> Data {
        let initialize = try symbol("lame_init",as:Init.self)
        let close = try symbol("lame_close",as:Params.self)
        guard let state = initialize() else { throw VoiceError(message:"MP3 编码器初始化失败") }
        defer { _ = close(state) }
        let options: [(String,Int32)] = [("lame_set_in_samplerate",16000),("lame_set_num_channels",1),("lame_set_brate",24),("lame_set_mode",3),("lame_set_quality",2),("lame_set_bWriteVbrTag",0)]
        for (name,value) in options {
            let set = try symbol(name,as:SetInt.self)
            guard set(state,value) >= 0 else { throw VoiceError(message:"MP3 参数不受支持") }
        }
        let params = try symbol("lame_init_params",as:Params.self)
        guard params(state) >= 0 else { throw VoiceError(message:"MP3 编码参数无效") }
        let encode = try symbol("lame_encode_buffer",as:Encode.self)
        let flush = try symbol("lame_encode_flush",as:Flush.self)
        var result = Data(); result.reserveCapacity(max(8192,pcm.count / 4))
        var output = [UInt8](repeating:0,count:20000)
        try pcm.withUnsafeBufferPointer { samples in
            var offset = 0
            while offset < samples.count {
                let count = min(8192,samples.count - offset)
                let size = encode(state,samples.baseAddress!.advanced(by:offset),nil,Int32(count),&output,Int32(output.count))
                guard size >= 0 else { throw VoiceError(message:"MP3 编码失败") }
                result.append(contentsOf:output.prefix(Int(size))); offset += count
            }
        }
        let count = flush(state,&output,Int32(output.count))
        guard count >= 0 else { throw VoiceError(message:"MP3 编码结束失败") }
        result.append(contentsOf:output.prefix(Int(count)))
        return result
    }
}

enum AudioPreparation {
    /// 20ms 能量检测,首尾各留250ms,只裁掉明显的首尾静音,不裁句中停顿。
    static func trimmedRange(_ pcm: [Int16]) -> Range<Int> {
        let frame = 320
        guard pcm.count >= frame * 5 else { return 0..<pcm.count }
        var first: Int?, last = 0
        for start in stride(from:0,to:pcm.count,by:frame) {
            let end = min(pcm.count,start + frame)
            var sum = 0.0
            for i in start..<end { let x = Double(pcm[i]) / 32768; sum += x * x }
            let db = 20 * log10(sqrt(sum / Double(end - start)) + 1e-7)
            if db > -50 { if first == nil { first = start }; last = end }
        }
        guard let first else { return 0..<pcm.count }
        return max(0,first - 4000)..<min(pcm.count,last + 4000)
    }
    static func prepare(_ input: URL) throws -> PreparedAudio {
        let started = Date()
        let file = try AVAudioFile(forReading:input,commonFormat:.pcmFormatInt16,interleaved:true)
        guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else { throw VoiceError(message:"录音格式不正确") }
        try file.read(into:buffer)
        guard let samples = buffer.int16ChannelData?[0] else { throw VoiceError(message:"无法读取录音") }
        let pcm = Array(UnsafeBufferPointer(start:samples,count:Int(buffer.frameLength)))
        let range = trimmedRange(pcm); let trimmed = Array(pcm[range])
        let rawBytes = ((try? input.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("voice-upload-\(UUID().uuidString).mp3")
        do {
            let data = try MP3Encoder().encode(trimmed)
            try data.write(to:target,options:.atomic)
            try? FileManager.default.removeItem(at:input)
            return PreparedAudio(url:target,rawBytes:rawBytes,bytes:data.count,rawSeconds:Double(pcm.count)/16000,seconds:Double(trimmed.count)/16000,preparationMS:Int(Date().timeIntervalSince(started)*1000))
        } catch {
            Paths.log("MP3 压缩失败,保留 WAV 兼容上传")
            try? FileManager.default.removeItem(at:target)
            return PreparedAudio(url:input,rawBytes:rawBytes,bytes:rawBytes,rawSeconds:Double(pcm.count)/16000,seconds:Double(pcm.count)/16000,preparationMS:Int(Date().timeIntervalSince(started)*1000))
        }
    }
}
