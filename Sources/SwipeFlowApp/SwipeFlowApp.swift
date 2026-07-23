import AppKit
import SwiftUI

@main
struct SwipeFlowApp: App {
    init() {
        guard let iconURL = Bundle.main.url(
            forResource: "AppIcon",
            withExtension: "icns"
        ), let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }

    var body: some Scene {
        WindowGroup {
            SourceBrowserView()
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}
