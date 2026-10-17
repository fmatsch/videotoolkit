import Foundation
import AVFoundation
import CoreImage
import VideoToolbox

struct ExportOptions {
    enum Codec: String, CaseIterable, Identifiable {
        case h264 = "H.264", hevc = "HEVC (H.265)"
        var id: String { rawValue }
        var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    }
    var codec: Codec = .hevc
    var quality: Double = 0.7        // 0.3 ... 1
    var applyVideo = true
    var applyAudio = true
}

struct ExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Exporter {
    static func export(asset: AVURLAsset, video: VideoSettings, audio: AudioSettings, noise: NoiseProfile?,
                       motion: MotionData?, lut: ColorLUT?, options: ExportOptions, to url: URL,
                       progress: @escaping (Double, String) -> Void) async throws {
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError(message: "Keine Videospur gefunden.")
        }
        let vs = options.applyVideo ? video : VideoSettings()
        let aSet = options.applyAudio ? audio : AudioSettings()
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let fps = max(1, Double(try await vTrack.load(.nominalFrameRate)))
        let duration = try await asset.load(.duration).seconds
        let totalFrames = max(1.0, duration * fps)

        // 1. Bewegungsdaten für Stabilisierung/Flackern über das gesamte Video
        var motionData = motion
        if vs.stabilize || vs.deflicker, motionData?.coversWholeAsset != true {
            progress(0, "Bewegung analysieren …")
            motionData = try await MotionPass.run(asset: asset, maxSeconds: nil) { progress(0.2 * $0, "Bewegung analysieren …") }
        }
        var offsets: [CGPoint] = [], zoom: CGFloat = 1, gains: [Float] = []
        if let m = motionData {
            if vs.stabilize {
                offsets = MotionPass.stabilizationOffsets(m, strength: vs.stabilizeStrength)
                zoom = FilterChain.zoomFor(offsets: offsets, analysisWidth: m.analysisWidth,
                                           analysisHeight: m.analysisWidth * Double(natural.height / natural.width))
            }
            if vs.deflicker { gains = MotionPass.deflickerGains(m) }
        }
        let offsetScale = motionData.map { Double(natural.width) / $0.analysisWidth } ?? 1

        // 2. Audio vorbereiten
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("VideoToolkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var processedAudioURL: URL?
        var processedChannels = 2
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        if hasAudio, !aSet.isNeutral {
            progress(0.2, "Audio verarbeiten …")
            if let pcm = try await AudioIO.read(asset: asset) {
                let out = AudioProcessor.process(pcm, settings: aSet, noise: noise) { progress(0.2 + 0.1 * $0, "Audio verarbeiten …") }
                let wav = tmp.appendingPathComponent("audio.wav")
                try AudioIO.writeWAV(out, to: wav)
                processedAudioURL = wav
                processedChannels = out.channels.count
            }
        }

        // 3. Writer
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let outW = (Int((natural.width * CGFloat(vs.upscale)).rounded()) + 1) & ~1
        let outH = (Int((natural.height * CGFloat(vs.upscale)).rounded()) + 1) & ~1
        let bitsPerPixel = 0.05 + 0.10 * options.quality
        let bitrate = Int(Double(outW * outH) * min(fps, 60) * bitsPerPixel * (options.codec == .hevc ? 0.65 : 1))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
        ]
        if options.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vSettings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        var aReader: AVAssetReader?
        var aOut: AVAssetReaderTrackOutput?
        if hasAudio {
            if let wav = processedAudioURL {
                let wasset = AVURLAsset(url: wav)
                if let t = try await wasset.loadTracks(withMediaType: .audio).first {
                    let r = try AVAssetReader(asset: wasset)
                    let o = AVAssetReaderTrackOutput(track: t, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                    ])
                    r.add(o)
                    let chans = processedChannels
                    aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                        AVNumberOfChannelsKey: chans, AVEncoderBitRateKey: 192_000 * chans / 2,
                    ])
                    aReader = r; aOut = o
                }
            } else if let t = try await asset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)   // Passthrough
                r.add(o)
                let hint = try await t.load(.formatDescriptions).first
                aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                aReader = r; aOut = o
            }
            if let aIn { aIn.expectsMediaDataInRealTime = false; writer.add(aIn) }
        }

        let vReader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        vOut.alwaysCopiesSampleData = false
        vReader.add(vOut)

        guard writer.startWriting() else { throw writer.error ?? ExportError(message: "Schreiben konnte nicht gestartet werden.") }
        guard vReader.startReading() else { throw vReader.error ?? ExportError(message: "Lesen konnte nicht gestartet werden.") }
        aReader?.startReading()
        writer.startSession(atSourceTime: .zero)

        // 4. Audio- und Videoschleife nebenläufig
        let audioTask = Task.detached { [aIn, aOut] in
            guard let aIn, let aOut else { return }
            while let sb = aOut.copyNextSampleBuffer() {
                while !aIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                try Task.checkCancellation()
                aIn.append(sb)
            }
            aIn.markAsFinished()
        }

        let ctx = FilterChain.makeContext()
        let rect = CGRect(x: 0, y: 0, width: Int(natural.width), height: Int(natural.height))
        var tempBuffers: [CVPixelBuffer] = []
        var tempIndex = 0
        var prevTemporal: CIImage?
        var aiSrc: CVPixelBuffer?
        let upscaler: AIUpscaler? = (vs.aiUpscale && vs.upscale > 1.01 && AIModels.upscalerAvailable) ? try await AIUpscaler.load() : nil
        var frameIndex = 0
        let baseProgress = (vs.stabilize || vs.deflicker) ? 0.3 : 0.1

        do {
            while let sb = vOut.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                while !vIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }

                var params = FrameParams()
                if frameIndex < offsets.count {
                    let o = offsets[frameIndex]
                    params.offset = CGPoint(x: o.x * offsetScale, y: o.y * offsetScale)
                    params.zoom = zoom
                }
                if frameIndex < gains.count { params.flickerGain = gains[frameIndex] }

                var img = FilterChain.stage1(CIImage(cvPixelBuffer: pb), vs, params)
                if vs.denoiseTemporal > 0 {
                    let mixed = FilterChain.temporal(img, previous: prevTemporal, strength: vs.denoiseTemporal)
                    if tempBuffers.count < 2 {
                        var b: CVPixelBuffer?
                        CVPixelBufferCreate(nil, Int(rect.width), Int(rect.height), kCVPixelFormatType_32BGRA,
                                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &b)
                        if let b { tempBuffers.append(b) }
                    }
                    if tempBuffers.count == 2 {
                        let target = tempBuffers[tempIndex]
                        ctx.render(mixed, to: target, bounds: rect, colorSpace: FilterChain.colorSpace)
                        tempIndex = 1 - tempIndex
                        prevTemporal = CIImage(cvPixelBuffer: target, options: [.colorSpace: FilterChain.colorSpace])
                        img = prevTemporal!
                    } else {
                        img = mixed
                        prevTemporal = nil
                    }
                }
                img = FilterChain.color(img, vs)
                if let ai = upscaler {
                    // KI-Hochskalierung: Farbe + Referenz anwenden, in Puffer rendern, 4× hochrechnen, auf Zielgröße skalieren
                    let base = FilterChain.applyLUT(img, vs, lut: lut)
                    if aiSrc == nil {
                        CVPixelBufferCreate(nil, Int(rect.width), Int(rect.height), kCVPixelFormatType_32BGRA,
                                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &aiSrc)
                    }
                    guard let src = aiSrc else { throw ExportError(message: "Pixelpuffer konnte nicht erzeugt werden.") }
                    ctx.render(base, to: src, bounds: rect, colorSpace: FilterChain.colorSpace)
                    let big = try ai.upscale4x(src)
                    let bigImg = CIImage(cvPixelBuffer: big, options: [.colorSpace: FilterChain.colorSpace])
                    img = FilterChain.scaleSharpen(bigImg, vs, scale: CGFloat(vs.upscale) / 4)
                } else {
                    img = FilterChain.finish(img, vs, lut: lut, scale: CGFloat(vs.upscale))
                }

                guard let pool = adaptor.pixelBufferPool else { throw ExportError(message: "Kein Pixelpuffer-Pool.") }
                var outBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
                guard let ob = outBuf else { throw ExportError(message: "Pixelpuffer konnte nicht erzeugt werden.") }
                ctx.render(img, to: ob, bounds: CGRect(x: 0, y: 0, width: outW, height: outH),
                           colorSpace: CGColorSpace(name: CGColorSpace.itur_709) ?? FilterChain.colorSpace)
                CVBufferSetAttachment(ob, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(ob, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(ob, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                guard adaptor.append(ob, withPresentationTime: pts) else {
                    throw writer.error ?? ExportError(message: "Frame konnte nicht geschrieben werden.")
                }
                frameIndex += 1
                if frameIndex % 10 == 0 {
                    progress(baseProgress + (0.97 - baseProgress) * min(1, Double(frameIndex) / totalFrames), "Video rendern …")
                }
            }
            vIn.markAsFinished()
            try await audioTask.value
        } catch {
            audioTask.cancel()
            vReader.cancelReading(); aReader?.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        progress(0.98, "Datei abschließen …")
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ExportError(message: "Export fehlgeschlagen.") }
        progress(1, "Fertig")
    }
}
