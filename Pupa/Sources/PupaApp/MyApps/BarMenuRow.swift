import SwiftUI

/// One row of the bar's menu, as data.
///
/// A SwiftUI `Menu` cannot be opened programmatically, so the guided tour can
/// never ring a row inside the real menu. It draws its own open-menu preview
/// instead (`TourMenuPreview`) — and both that preview and the real
/// `MyAppBottomBar.moreMenu` build their rows from this one list, so the
/// picture the tour shows cannot drift from the menu the user then opens.
///
/// Order here is **declaration** order, which is what the real `Menu` consumes.
/// iOS reverses a bottom-anchored menu's whole item list, so the preview
/// reverses this to match what the user actually sees.
enum BarMenuRow: Hashable, CaseIterable {
    case agents
    case history
    case orchestrator
    case myApps
    case settings

    var title: String {
        switch self {
        case .agents: "Agents"
        case .history: "History"
        case .orchestrator: "Orchestrator"
        case .myApps: "MyApps"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .agents: "person.2"
        case .history: "clock"
        case .orchestrator: "square.stack.3d.up.fill"
        case .myApps: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }

    /// Which group this row belongs to. The menu is grouped one axis per
    /// section: this scope's pages, which scope you're in, then app-wide.
    /// Dividers fall between groups.
    var group: Int {
        switch self {
        case .agents, .history: 0
        case .orchestrator, .myApps: 1
        case .settings: 2
        }
    }

    /// The rows a bar shows, in declaration order.
    ///
    /// - `isMyApp`: false on the orchestrator's bar, which omits History (no
    ///   canvas change-log) and Orchestrator (you're already there).
    /// - `hasMyApps`: false on macOS, where the sidebar column is permanent and
    ///   a row that opens it would be redundant.
    static func rows(isMyApp: Bool, hasMyApps: Bool) -> [BarMenuRow] {
        var rows: [BarMenuRow] = [.agents]
        if isMyApp { rows.append(.history) }
        if isMyApp { rows.append(.orchestrator) }
        if hasMyApps { rows.append(.myApps) }
        rows.append(.settings)
        return rows
    }
}
