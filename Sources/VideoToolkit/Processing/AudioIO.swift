import Foundation
import AVFoundation

/// Nicht-interleaved Float-Audio im Speicher.
struct PCMAudio {
    var channels: [[Float]]
    var sampleRate: Double
    var frames: Int { channels.first?.count ?? 0 }
    var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    var mono: [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var m = channels[0]
        for c in 1..<channels.count { for i in 0..<m.count { m[i] += channels[c][i] } }
        let s = 1 / Float(channels.count)
        for i in 0..<m.count { m[i] *= s }
        return m
    }
}

enum AudioIO {
    static let workRate = 48_000.0

    /// Dekodiert die Audiospur (optional nur einen Zeitbereich) nach Float32, 48 kHz, max. Stereo.
    static func read(asset: AVAsset, start: Double = 0, duration: Double? = nil) async throws -> PCMAudio? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        var channelCount = 2
        if let desc = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            channelCount = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: workRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        if start > 0 || duration != nil {
            let d = duration.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: d)
        }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var chans = [[Float]](repeating: [], count: channelCount)
        if let d = duration { for c in 0..<channelCount { chans[c].reserveCapacity(Int(d * workRate)) } }
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let frames = data.count / channelCount
            if channelCount == 1 {
                chans[0].append(contentsOf: data)
            } else {
                for c in 0..<channelCount {
                    chans[c].append(contentsOf: (0..<frames).lazy.map { data[$0 * channelCount + c] })
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard chans[0].count > 0 else { return nil }
        return PCMAudio(channels: chans, sampleRate: workRate)
    }

    /// Schreibt Float32-WAV (für Zwischenschritte und Vorschau).
    static func writeWAV(_ pcm: PCMAudio, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.sampleRate,
                                   channels: AVAudioChannelCount(pcm.channels.count), interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        var pos = 0
        while pos < pcm.frames {
            let n = min(chunk, pcm.frames - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<pcm.channels.count {
                pcm.channels[c].withUnsafeBufferPointer {
                    buf.floatChannelData![c].update(from: $0.baseAddress! + pos, count: n)
                }
            }
            try file.write(from: buf)
            pos += n
        }
    }
}
