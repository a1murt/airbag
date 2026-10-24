import AirbagCore
import AppKit
import SwiftUI

/// The main window: projects in the sidebar (each one opens its Timeline), then Radar and Guard.
struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var addError: String?
    @State private var dropTargeted = false
    /// A folder just added: selected as soon as its store shows up in the project list.
    @State private var pendingSelection: String?

    enum SidebarItem: Hashable { case project(String), radar, guardLog }

    var selection: Binding<SidebarItem?> {
        Binding(get: {
            switch model.selectedTab {
            case .timeline: return model.selectedRoot.map(SidebarItem.project)
            case .radar: return .radar
            case .guardLog: return .guardLog
            }
        }, set: { item in
            switch item {
            case .project(let root)?: model.selectedRoot = root; model.selectedTab = .timeline
            case .radar?: model.selectedTab = .radar
            case .guardLog?: model.selectedTab = .guardLog
            case nil: return
            }
            model.scheduleRadar()
        })
    }

    /// Folders being added whose first snapshot has not finished yet (they have no store row so far).
    var addingRoots: [String] {
        model.snapshottingRoots.filter { r in !model.projects.contains { $0.root == r } }.sorted()
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                if !model.projects.isEmpty || !addingRoots.isEmpty {
                    projectsSection
                }
                Section {
                    Label(String(localized: MainTab.radar.title), systemImage: MainTab.radar.symbol)
                        .badge(model.leftRunning.count)
                        .tag(SidebarItem.radar)
                    Label(String(localized: MainTab.guardLog.title), systemImage: MainTab.guardLog.symbol)
                        .badge(model.needsApproval.count + model.unseenGuards.count)
                        .tag(SidebarItem.guardLog)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in add(urls) } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2).padding(6).allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button { showAddPanel() } label: { Label("Add Project…", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .help(Text("Choose a project folder for Airbag to protect."))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            detail
                .overlay(alignment: .bottom) {
                    if let toast = model.toast {
                        ToastView(toast: toast)
                            .frame(maxWidth: 560)
                            .padding(.horizontal, 20).padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.toast?.id)
        }
        .frame(minWidth: 680, minHeight: 480)
        .onAppear { model.mainWindowVisible = true; model.refreshAll() }
        .onDisappear { model.mainWindowVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: .airbagAddProject)) { _ in showAddPanel() }
        .onChange(of: model.addProjectRequested, initial: true) { _, requested in
            guard requested else { return }
            model.addProjectRequested = false
            DispatchQueue.main.async { showAddPanel() }
        }
        .onChange(of: model.projects) { _, projects in
            if let root = pendingSelection, projects.contains(where: { $0.root == root }) {
                model.selectedRoot = root
                model.selectedTab = .timeline
                pendingSelection = nil
            }
        }
        .alert(Text(verbatim: addError ?? ""), isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })) {}
    }

    var projectsSection: some View {
        Section("Projects") {
            ForEach(model.projects) { p in
                // `.tag` must be the outermost modifier: after `.badge` or `.contextMenu` the list no longer sees
                // it, no row is selectable and clicks in the sidebar do nothing.
                ProjectSidebarRow(project: p, snapshotting: model.snapshottingRoots.contains(p.root))
                    .contextMenu {
                        Button("Take Snapshot") { model.snapshotNow(p.root) }.disabled(!p.rootExists)
                        Button("Show in Finder") { model.revealInFinder(p.root) }.disabled(!p.rootExists)
                    }
                    .tag(SidebarItem.project(p.root))
            }
            ForEach(addingRoots, id: \.self) { root in
                HStack(spacing: 6) {
                    Label { Text(verbatim: (root as NSString).lastPathComponent).lineLimit(1) } icon: { Image(systemName: "folder") }
                    Spacer(minLength: 4)
                    ProgressView().controlSize(.mini)
                }
                .tag(SidebarItem.project(root))
            }
        }
    }

    @ViewBuilder var detail: some View {
        switch model.selectedTab {
        // One screen per project, so expansion, search and held entries never leak from one project to the next.
        case .timeline: TimelineScreen(preview: model.frozen).id(model.selectedRoot ?? "")
        case .radar: RadarScreen()
        case .guardLog: GuardScreen()
        }
    }

    /// The folder panel of "Add Project…" (the sidebar button, ⌘O and the empty Timeline).
    func showAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        panel.message = String(localized: "Choose a project folder for Airbag to protect.")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { _ = add(panel.urls) }
        }
        if let window = NSApp.keyWindow, window.styleMask.contains(.titled) { panel.beginSheetModal(for: window, completionHandler: done) }
        else { panel.begin(completionHandler: done) }
    }

    /// Protects the given folders (files are ignored); the first one added opens. Errors are shown in one alert.
    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        let folders = urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !folders.isEmpty else { return false }
        var errors: [String] = []
        var first: String?
        for url in folders {
            if let error = model.addProject(url, announce: false) { errors.append(error) }
            else if first == nil { first = FileSystem.canonicalPath(url.path) ?? url.path }
        }
        if let first {
            pendingSelection = first
            model.selectedRoot = first
            model.selectedTab = .timeline
        }
        if !errors.isEmpty { addError = errors.joined(separator: "\n") }
        return true
    }
}

/// A project in the sidebar: name, a green dot while an agent session runs there, and when it was last snapshotted.
struct ProjectSidebarRow: View {
    let project: ProjectRow
    let snapshotting: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: project.name).lineLimit(1).truncationMode(.middle)
                    caption.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                if project.rootExists {
                    Image(systemName: project.isWorktree ? "arrow.triangle.branch" : "folder")
                } else {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(Theme.danger)
                }
            }
            Spacer(minLength: 4)
            if project.liveSessions > 0 {
                Circle().fill(Theme.ok).frame(width: 7, height: 7)
                    .help(Text("live session")).accessibilityLabel(Text("live session"))
            }
        }
        .help(Text(verbatim: (project.root as NSString).abbreviatingWithTildeInPath))
    }

    var caption: Text {
        if !project.rootExists { return Text("Folder missing") }
        if snapshotting { return Text("snapshot in progress…") }
        if let last = project.lastSnapshotAt { return Text(verbatim: String(localized: "snapshot \(RelativeTime.short(ms: last))")) }
        return Text("no snapshots yet")
    }
}
