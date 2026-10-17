import Foundation
import AVFoundation
import CoreImage

/// Rendert Vorher/Nachher-Standbilder für die Vorschau.
final class PreviewRenderer {
    let context = FilterChain.makeContext()
    private let generator: AVAssetImageGenerator

    init(asset: AVAsset) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)
    }

    func frame(at time: Double) async -> CGImage? {
        try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    func render(frame: CGImage, settings: VideoSettings, lut: ColorLUT?, params: FrameParams) -> CGImage? {
        let ci = CIImage(cgImage: frame)
        var img = FilterChain.stage1(ci, settings, params)
        img = FilterChain.color(img, settings)
        img = FilterChain.finish(img, settings, lut: lut, scale: 1)
        return context.createCGImage(img, from: ci.extent, format: .RGBA8, colorSpace: FilterChain.colorSpace)
    }
}
