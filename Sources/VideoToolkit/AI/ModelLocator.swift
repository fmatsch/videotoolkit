import Foundation

/// Findet die eingebetteten Core-ML-Modelle (in der App unter Contents/Resources/Models, beim Entwickeln im Projektordner).
enum ModelLocator {
    /// ~/Library/Application Support/VideoToolkit (in der Sandbox: im App-Container)
    static var supportDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VideoToolkit", isDirectory: true)
    }

    /// Kopiert einen vom Nutzer gewählten Modellordner nach Application Support/Models/<relativ>.
    static func importModel(from source: URL, as relative: String) throws {
        guard let base = supportDirectory?.appendingPathComponent("Models").appendingPathComponent(relative) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.copyItem(at: source, to: base)
    }

    static func url(_ relative: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Models")) }
        if let env = ProcessInfo.processInfo.environment["VT_MODELS"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Models"))
        if let s = supportDirectory { candidates.append(s.appendingPathComponent("Models")) }
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
    /// Lädt/kompiliert Modelle, die vor einer (synchronen) Audioverarbeitung bereit sein müssen.
    static func prepare(audio s: AudioSettings) async {
        if s.aiSeparate, DemucsSeparator.isAvailable { try? await DemucsSeparator.prepare() }
    }

    static var deepFilterAvailable: Bool { ModelLocator.url("DeepFilterNet3/DeepFilterNet3.mlmodelc") != nil && ModelLocator.url("DeepFilterNet3/window.f32") != nil }
    static var upscalerAvailable: Bool { ModelLocator.url("RealESRGAN/RealESRGAN-x4v3.mlpackage") != nil }
}
