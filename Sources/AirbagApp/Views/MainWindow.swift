import AirbagCore
import AppKit
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedTab }, set: { if let t = $0 { model.selectedTab = t; model.scheduleRadar() } })) {
                ForEach(MainTab.allCases) { tab in
                    // `.tag` must be the outermost modifier: after `.badge` the list no longer sees it, no row is
                    // selectable and clicks in the sidebar do nothing.
                    Label(String(localized: tab.title), systemImage: tab.symbol)
                        .badge(tab == .guardLog ? model.attentionGuards.count : (tab == .radar ? model.orphans.count : 0))
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.selectedTab {
            case .timeline: TimelineScreen(expandFirst: model.frozen)
            case .radar: RadarScreen()
            case .guardLog: GuardScreen()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { model.mainWindowVisible = true; model.refreshAll() }
        .onDisappear { model.mainWindowVisible = false }
    }
}
