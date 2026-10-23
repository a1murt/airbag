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
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // Welcome and Restore open only from their flows, never from the Window menu (the app has one while a window is open).
        Window(Text("Welcome to Airbag"), id: "welcome") {
            OnboardingView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window(Text("Airbag"), id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 680)

        Window(Text("Restore"), id: "restore") {
            RestoreWindow().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

extension AppModel {
    static let shared: AppModel = {
        let demo = CommandLine.arguments.contains("--render-previews") || CommandLine.arguments.contains("--render-demo")
        return AppModel(demo: demo)
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--render-previews") {
            let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            MainActor.assumeIsolated { PreviewRenderer.renderAll(to: dir) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo") {
            let dir = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            MainActor.assumeIsolated { PreviewRenderer.renderDemo(to: dir) }
            exit(0)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { self?.updateActivationPolicy(closing: closing) }
            })
        }
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// A menu bar app with real windows: while one is open the app is in the Dock and ⌘-Tab, so the window cannot get
    /// lost behind other apps; with none open it is back to the menu bar only. The popover is not a titled window.
    @MainActor private func updateActivationPolicy(closing: NSWindow?) {
        guard !NSApp.isHidden else { return }
        let windowOpen = NSApp.windows.contains { w in
            w !== closing && (w.isVisible || w.isMiniaturized) && w.styleMask.contains(.titled) && w.level == .normal
        }
        let wanted: NSApplication.ActivationPolicy = windowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}
