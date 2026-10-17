import Foundation
import CoreML
import CoreVideo

/// 4×-Hochskalierung mit Real-ESRGAN (realesr-general-x4v3, Core ML, lokal), kachelweise mit Überlappung.
final class AIUpscaler {
    static let tile = 256, pad = 16, scale = 4
    private let model: MLModel

    private static var cached: AIUpscaler?

    static func load() async throws -> AIUpscaler {
        if let c = cached { return c }
        guard let pkg = ModelLocator.url("RealESRGAN/RealESRGAN-x4v3.mlpackage") else { throw CocoaError(.fileNoSuchFile) }
        // Kompiliertes Modell im Application-Support-Ordner zwischenspeichern
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VideoToolkit", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let compiled = support.appendingPathComponent("RealESRGAN-x4v3.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let tmp = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: tmp, to: compiled)
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        let up = AIUpscaler(model: try MLModel(contentsOf: compiled, configuration: cfg))
        cached = up
        return up
    }

    private init(model: MLModel) { self.model = model }

    /// src: BGRA-Puffer → neuer BGRA-Puffer in 4-facher Größe.
    func upscale4x(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let S = Self.scale, T = Self.tile, P = Self.pad, core = T - 2 * P
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, w * S, h * S, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &dst)
        guard let out = dst else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(out, []) }
        let sBase = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self), sBpr = CVPixelBufferGetBytesPerRow(src)
        let dBase = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self), dBpr = CVPixelBufferGetBytesPerRow(out)

        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float16)
        let inPtr = input.dataPointer.assumingMemoryBound(to: Float16.self)
        let plane = T * T
        var cy = 0
        while cy < h {
            var cx = 0
            while cx < w {
                // Eingabekachel mit Randwiederholung füllen (RGB, 0...1)
                for ty in 0..<T {
                    let sy = min(h - 1, max(0, cy - P + ty))
                    let row = sBase + sy * sBpr
                    for tx in 0..<T {
                        let sx = min(w - 1, max(0, cx - P + tx))
                        let px = row + sx * 4
                        let i = ty * T + tx
                        inPtr[i] = Float16(Float(px[2]) / 255)           // R
                        inPtr[plane + i] = Float16(Float(px[1]) / 255)   // G
                        inPtr[2 * plane + i] = Float16(Float(px[0]) / 255) // B
                    }
                }
                let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)]))
                guard let o = res.featureValue(for: "output")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
                let st = o.strides.map(\.intValue)      // [1, C, H, W]
                let isHalf = o.dataType == .float16
                let hp = o.dataPointer.assumingMemoryBound(to: Float16.self), fp = o.dataPointer.assumingMemoryBound(to: Float.self)
                @inline(__always) func val(_ c: Int, _ y: Int, _ x: Int) -> Float {
                    let idx = c * st[1] + y * st[2] + x * st[3]
                    return isHalf ? Float(hp[idx]) : fp[idx]
                }
                let cw = min(core, w - cx), ch = min(core, h - cy)
                for oy in 0..<(ch * S) {
                    let drow = dBase + (cy * S + oy) * dBpr
                    for ox in 0..<(cw * S) {
                        let ty = P * S + oy, tx = P * S + ox
                        let d = drow + (cx * S + ox) * 4
                        d[2] = UInt8(max(0, min(255, val(0, ty, tx) * 255 + 0.5)))
                        d[1] = UInt8(max(0, min(255, val(1, ty, tx) * 255 + 0.5)))
                        d[0] = UInt8(max(0, min(255, val(2, ty, tx) * 255 + 0.5)))
                        d[3] = 255
                    }
                }
                cx += core
            }
            cy += core
        }
        return out
    }
}
