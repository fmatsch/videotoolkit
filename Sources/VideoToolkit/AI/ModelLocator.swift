import Foundation

/// Findet die eingebetteten Core-ML-Modelle (in der App unter Contents/Resources/Models, beim Entwickeln im Projektordner).
enum ModelLocator {
    static func url(_ relative: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Models")) }
        if let env = ProcessInfo.processInfo.environment["VT_MODELS"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Models"))
        // Binary liegt in .build/<config>/VideoToolkit → Projektordner ist drei Ebenen höher
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Models"))
        for base in candidates {
            let u = base.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

enum AIModels {
    static var deepFilterAvailable: Bool { ModelLocator.url("DeepFilterNet3/DeepFilterNet3.mlmodelc") != nil && ModelLocator.url("DeepFilterNet3/window.f32") != nil }
    static var upscalerAvailable: Bool { ModelLocator.url("RealESRGAN/RealESRGAN-x4v3.mlpackage") != nil }
}
