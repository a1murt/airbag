import AirbagCore
import AppKit
import SwiftUI

@main
struct AirbagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            Image(systemName: "shield.lefthalf.filled")
                .accessibilityLabel(Text("menubar.accessibility"))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this also keeps `swift run` dev launches out of the Dock.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct PopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("popover.title").font(.headline)
            Text("popover.subtitle").font(.subheadline).foregroundStyle(.secondary)
            Divider()
            Text(verbatim: AirbagVersion.line).font(.caption).foregroundStyle(.tertiary)
            Button("popover.quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }
}
