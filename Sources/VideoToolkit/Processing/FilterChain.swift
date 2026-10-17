import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation

/// 3D-LUT aus dem Referenzabgleich (vollständige Stärke); wird je nach Stärke mit der Identität gemischt.
final class ColorLUT {
    static let dimension = 33
    /// Pro Kanal 256 Stützstellen (0...1).
    let curves: [[Float]]
    private var cache: [Int: Data] = [:]
    init(curves: [[Float]]) { self.curves = curves }

    func cubeData(strength: Double) -> Data {
        let key = Int((strength * 100).rounded())
        if let d = cache[key] { return d }
        let n = Self.dimension
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        let s = Float(strength)
        func map(_ c: Int, _ v: Float) -> Float {
            let x = v * 255
            let i = min(254, Int(x)); let f = x - Float(i)
            let m = curves[c][i] * (1 - f) + curves[c][i + 1] * f
            return v + (m - v) * s
        }
        var idx = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            floats[idx] = map(0, Float(r) / Float(n - 1))
            floats[idx + 1] = map(1, Float(g) / Float(n - 1))
            floats[idx + 2] = map(2, Float(b) / Float(n - 1))
            floats[idx + 3] = 1
            idx += 4
        } } }
        let d = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        cache[key] = d
        return d
    }
}

/// Zusätzliche Daten pro Frame.
struct FrameParams {
    var offset = CGPoint.zero      // Stabilisierungsversatz in Bildpixeln (CI-Koordinaten)
    var zoom: CGFloat = 1
    var rotation: CGFloat = 0     // rad, um die Bildmitte
    var shear: CGFloat = 0        // Rolling-Shutter: x += shear * (y - Mitte)
    var flickerGain: Float = 1
    var noiseOffset = CGPoint.zero   // verschiebt das Dither-Rauschen pro Frame
}

enum FilterChain {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
    }

    // MARK: Objektiv & Bildfehler (vor der Stabilisierung, in der Reihenfolge der Bildentstehung rückwärts)

    private static let lensKernel = CIWarpKernel(source: """
        kernel vec2 lensWarp(vec2 center, float k, float rn) {
            vec2 d = destCoord() - center;
            float r2 = dot(d, d) * rn;
            return center + d * (1.0 + k * r2);
        }
        """)
    private static let vignetteKernel = CIColorKernel(source: """
        kernel vec4 devignette(__sample s, vec2 center, float strength, float rn) {
            vec2 d = destCoord() - center;
            float r2 = dot(d, d) * rn;
            float g = 1.0 + strength * (0.5 * r2 + 0.5 * r2 * r2);
            return vec4(s.rgb * g, s.a);
        }
        """)

    static func pre(_ input: CIImage, _ s: VideoSettings) -> CIImage {
        var img = input
        let rect = input.extent
        if s.deinterlace {
            // vertikales 1-2-1-Filter glättet Kammartefakte
            img = img.applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: [0, 0.25, 0, 0, 0.5, 0, 0, 0.25, 0], count: 9), "inputBias": 0,
            ]).cropped(to: rect)
        }
        let center = CIVector(x: rect.midX, y: rect.midY)
        let rn = 1 / Double(max(1, (rect.width * rect.width + rect.height * rect.height) / 4))
        if abs(s.lensCorrection) > 0.005, let k = lensKernel {
            // positiv = Tonnenverzeichnung (Weitwinkel) entfernen, negativ = Kissenverzeichnung
            let kk = -0.35 * s.lensCorrection
            if let out = k.apply(extent: rect, roiCallback: { _, r in r.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25) },
                                 image: img.clampedToExtent(), arguments: [center, kk, rn]) { img = out }
        }
        if s.vignetteFix > 0.005, let k = vignetteKernel,
           let out = k.apply(extent: rect, arguments: [img, center, s.vignetteFix * 2.4, rn]) { img = out }
        return img.cropped(to: rect)
    }

    // Stufe 1: Objektiv/Bildfehler, Stabilisierung, Rolling Shutter, Flacker
    static func stage1(_ input: CIImage, _ s: VideoSettings, _ p: FrameParams) -> CIImage {
        var img = pre(input, s)
        let rect = input.extent
        if (s.stabilize || s.rollingShutter > 0.001) && (p.offset != .zero || p.zoom != 1 || p.rotation != 0 || p.shear != 0) {
            let cx = rect.midX, cy = rect.midY
            var t = CGAffineTransform(translationX: -cx, y: -cy)
            if abs(p.shear) > 1e-7 { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: p.shear, d: 1, tx: 0, ty: 0)) }
            if abs(p.rotation) > 1e-7 { t = t.concatenating(CGAffineTransform(rotationAngle: p.rotation)) }
            t = t.concatenating(CGAffineTransform(scaleX: p.zoom, y: p.zoom))
            t = t.concatenating(CGAffineTransform(translationX: cx + p.offset.x, y: cy + p.offset.y))
            img = img.clampedToExtent().transformed(by: t).cropped(to: rect)
        }
        if s.deflicker, abs(p.flickerGain - 1) > 0.002 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(Double(p.flickerGain))])
        }
        return img
    }

    /// Bewegungsadaptive zeitliche Rauschminderung: statische Bereiche werden mit dem Vorgänger gemischt.
    static func temporal(_ cur: CIImage, previous: CIImage?, strength: Double) -> CIImage {
        guard strength > 0, let prev = previous, prev.extent == cur.extent else { return cur }
        let rect = cur.extent
        let diff = cur.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: prev])
        // Differenz glätten (Rauschen mitteln), in Maske umrechnen: groß = Bewegung
        let blurred = diff.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(2, rect.width / 320)]).cropped(to: rect)
        let gain = 16.0
        let m = CIFilter.colorMatrix()
        m.inputImage = blurred
        let v = CIVector(x: gain / 3, y: gain / 3, z: gain / 3, w: 0)
        m.rVector = v; m.gVector = v; m.bVector = v
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: -0.65, y: -0.65, z: -0.65, w: 1)
        let mask = m.outputImage!.applyingFilter("CIColorClamp")
        // Mischung aus Vorgänger und aktuellem Bild
        let a = CGFloat(min(0.85, strength * 0.85))
        let mixed = cur.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: prev, kCIInputTimeKey: a,
        ])
        // Bewegung (Maske = 1) → aktuelles Bild, sonst → Mischung
        return cur.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: mixed, kCIInputMaskImageKey: mask,
        ]).cropped(to: rect)
    }

    /// Stufe 2 bis einschließlich Farbe (ohne Referenz, Schärfe, Skalierung) – wird auch für das Referenz-LUT benutzt.
    static func color(_ input: CIImage, _ s: VideoSettings) -> CIImage {
        var img = input
        let rect = input.extent
        if s.denoiseSpatial > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.01 + 0.05 * s.denoiseSpatial,
                "inputSharpness": 0.35,
            ])
        }
        if abs(s.exposure) > 0.005 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
        }
        if abs(s.temperature) > 0.005 || abs(s.tint) > 0.005 {
            let r = 1 + 0.25 * s.temperature, b = 1 - 0.25 * s.temperature, g = 1 - 0.2 * s.tint
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        if s.shadows > 0.005 || s.highlights > 0.005 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": s.shadows * 1.2,
                "inputHighlightAmount": 1 - s.highlights * 0.8,
            ])
        }
        if abs(s.contrast - 1) > 0.005 || abs(s.saturation - 1) > 0.005 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: s.contrast, kCIInputSaturationKey: s.saturation,
            ])
        }
        if abs(s.vibrance) > 0.005 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance])
        }
        return img.cropped(to: rect)
    }

    /// Referenz-LUT (Farb-/Tonwertangleichung).
    static func applyLUT(_ input: CIImage, _ s: VideoSettings, lut: ColorLUT?) -> CIImage {
        guard s.referenceStrength > 0.005, let lut else { return input }
        return input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": ColorLUT.dimension,
            "inputCubeData": lut.cubeData(strength: s.referenceStrength),
            "inputColorSpace": colorSpace,
        ])
    }

    /// Lanczos-Skalierung um `scale` und anschließendes Schärfen.
    static func scaleSharpen(_ input: CIImage, _ s: VideoSettings, scale: CGFloat) -> CIImage {
        var img = input
        let target = input.extent.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        if abs(scale - 1) > 0.01 {
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
            ])
        }
        if s.sharpen > 0.01 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(1.0, img.extent.width / 900),
                kCIInputIntensityKey: s.sharpen * 0.9,
            ])
        }
        return img.cropped(to: target)
    }

    static func finish(_ input: CIImage, _ s: VideoSettings, lut: ColorLUT?, scale: CGFloat, noiseOffset: CGPoint = .zero) -> CIImage {
        dither(scaleSharpen(applyLUT(input, s, lut: lut), s, scale: scale), s, offset: noiseOffset)
    }

    /// Feines Rauschen (Dither) verdeckt Streifen in Verläufen nach der Neukodierung.
    static func dither(_ input: CIImage, _ s: VideoSettings, offset: CGPoint) -> CIImage {
        guard s.deband > 0.005, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return input }
        let amp = 0.012 * s.deband
        let mono = noise.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0),
                "inputGVector": CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0),
                "inputBVector": CIVector(x: 1.0 / 3, y: 1.0 / 3, z: 1.0 / 3, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            // Grauwert 0,5 ± amp (Mittelwert der Summe dreier Gleichverteilungen ≈ 0,5 mit kleiner Streuung → verstärken)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 6 * amp, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 6 * amp, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 6 * amp, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - 3 * amp, y: 0.5 - 3 * amp, z: 0.5 - 3 * amp, w: 0),
            ])
            .cropped(to: input.extent)
        return mono.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: input]).cropped(to: input.extent)
    }
}
