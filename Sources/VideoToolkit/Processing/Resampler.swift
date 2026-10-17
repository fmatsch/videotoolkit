import Foundation
import AVFoundation

enum Resampler {
    /// Wandelt einen Kanal mit AVAudioConverter (hochwertig) in eine andere Abtastrate um.
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !x.isEmpty else { return x }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return x }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(x.count))!
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let outCap = AVAudioFrameCount(Double(x.count) * to / from) + 4096
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)!
        var fed = false
        var error: NSError?
        let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return inBuf
        }
        guard status != .error, error == nil else { return x }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
