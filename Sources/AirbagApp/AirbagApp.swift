import AirbagCore
import AppKit
import SwiftUI

@main
struct AirbagApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(model.iconState, badge: model.badge))
                .accessibilityLabel(Text("Airbag"))
        }
        .menuBarExtraStyle(.window)

        Window(Text("Airbag"), id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 680)

        Window(Text("Restore"), id: "restore") {
            RestoreWindow().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

extension AppModel {
    static let shared: AppModel = {
        let demo = CommandLine.arguments.contains("--render-previews")
        return AppModel(demo: demo)
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--render-previews") {
            let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            MainActor.assumeIsolated { PreviewRenderer.renderAll(to: dir) }
            exit(0)
        }
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}
