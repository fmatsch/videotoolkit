import SwiftUI

struct VideoToolkitApp: App {
    @StateObject private var project = Project()

    var body: some Scene {
        Window("Video Toolkit", id: "main") {
            ContentView()
                .environmentObject(project)
                .frame(minWidth: 1000, minHeight: 640)
                .onOpenURL { project.open($0) }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Video öffnen …") { NotificationCenter.default.post(name: .openVideoRequested, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Toggle("Expertenmodus", isOn: $project.expertMode).keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}
