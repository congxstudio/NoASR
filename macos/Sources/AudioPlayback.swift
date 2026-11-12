import Foundation
import AVFoundation
import CoreAudio

enum AudioPlayback {
    static var outputUID: String? {
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var device:AudioDeviceID = 0; var size:UInt32 = 4
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var value: Unmanaged<CFString>?; size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device,&address,0,nil,&size,&value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func gain(peak: Float) -> Float {
        guard peak > 0.0001 else { return 1 }
        return max(1,min(8,0.89 / peak))
    }
    // 仅生成回放副本，保持上传和历史原文件不变。峰值限制避免放大后削波。
    static func enhanced(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading:url)
        guard file.length > 0, file.length <= 30_000_000,
              let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)) else {
            throw VoiceError(message:"录音无法解码")
        }
        try file.read(into:buffer)
        guard let channels = buffer.floatChannelData else { throw VoiceError(message:"录音格式不支持回放增强") }
        let count = Int(buffer.frameLength); let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating:0,count:count); var peak:Float = 0
        for i in 0..<count {
            for c in 0..<channelCount { mono[i] += channels[c][i] / Float(channelCount) }
            peak = max(peak,abs(mono[i]))
        }
        let gain = gain(peak:peak)
        var data = Data()
        func text(_ s:String) { data.append(contentsOf:s.utf8) }
        func u16(_ n:UInt16) { var v=n.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        func u32(_ n:UInt32) { var v=n.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        let rate = UInt32(buffer.format.sampleRate)
        text("RIFF"); u32(UInt32(36+count*2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(rate); u32(rate*2); u16(2); u16(16); text("data"); u32(UInt32(count*2))
        for value in mono { u16(UInt16(bitPattern:Int16(max(-1,min(1,value*gain))*32767))) }
        Paths.log("回放增强: 增益=\(String(format:"%.1f",20*log10(gain)))dB")
        return data
    }
}
