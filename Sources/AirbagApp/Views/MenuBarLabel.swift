import AirbagCore
import AppKit
import SwiftUI

/// The menu bar label. It is always alive, so it also opens windows the model asks for (notifications, shortcuts,
/// reopening the app) and the first-run window once.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var accessibilityText: Text {
        switch model.iconState {
        case .needsYou: return Text("Airbag: an agent is waiting for you")
        case .degraded: return Text("Airbag: protection needs attention")
        case .paused: return Text("Airbag: paused until \(model.pausedUntil.map(RelativeTime.moment) ?? "")")
        case .idle: return Text("Airbag: nothing protected")
        case .protected: return model.badge ? Text("Airbag: something new to look at") : Text("Airbag: projects protected")
        }
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(model.iconState, badge: model.badge, tick: model.tick))
            .accessibilityLabel(accessibilityText)
            .task {
                if model.needsOnboarding {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    perform(.welcome)
                } else if let i = CommandLine.arguments.firstIndex(of: "--show") {
                    // `open -a Airbag --args --show radar`: the main window on a tab (timeline, radar, guard), or settings.
                    let name = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    perform(name == "settings" ? .settings : .main(MainTab(rawValue: name) ?? .timeline))
                }
            }
            .onChange(of: model.windowRequest) { _, request in
                guard let request else { return }
                model.windowRequest = nil
                perform(request)
            }
    }

    /// Opens a window and brings Airbag forward (it is a menu bar app, so it is usually not active).
    func perform(_ request: WindowRequest) {
        NSApp.activate(ignoringOtherApps: true)
        switch request {
        case .main(let tab):
            model.selectedTab = tab
            openWindow(id: "main")
        case .settings: openSettings()
        case .restore: openWindow(id: "restore")
        case .welcome: openWindow(id: "welcome")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
