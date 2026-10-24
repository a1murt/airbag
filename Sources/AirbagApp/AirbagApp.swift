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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Window(Text("Airbag"), id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 680)
        .commands { AirbagCommands(model: model) }

        Window(Text("Restore"), id: "restore") {
            RestoreWindow().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Settings {
            SettingsScreen().environmentObject(model)
        }
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
        Notifier.shared.configure()
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

    /// Double-clicking Airbag (Finder, Spotlight, `open -a`) while it runs opens its window instead of nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.reopen() } }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stop() }
    }
}

/// Menu commands while a window is open: views (⌘1–3), snapshots, undo of the last agent change, help.
struct AirbagCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.addProjectRequested = true; model.windowRequest = .main(model.selectedTab) }
                .keyboardShortcut("o")
            Button("Take Snapshot") { if let root = model.selectedRoot { model.snapshotNow(root) } }
                .keyboardShortcut("s")
                .disabled(model.selectedRoot == nil)
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Undo Last Agent Change") { model.undoLatest() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.latestUndoable == nil)
            Button("Undo Restore") { model.undoLastRestore() }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(model.lastRestore == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { i, tab in
                Button(String(localized: tab.title)) { model.windowRequest = .main(tab) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Link("Airbag on GitHub", destination: URL(string: "https://github.com/a1murt/airbag")!)
            Link("Report a Problem…", destination: URL(string: "https://github.com/a1murt/airbag/issues/new")!)
        }
    }
}

extension Notification.Name {
    /// "Add Project…" from the menu: the main window shows the folder panel.
    static let airbagAddProject = Notification.Name("dev.airbag.addProject")
}
