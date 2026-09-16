import SwiftUI

/// One section of the Active notifications list, plus the rule that builds
/// them. Outside the view so the ordering is testable.
struct NotificationOriginGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// Nil for the non-miniApp sections, which take the secondary colour.
    let tint: Color?
    let rows: [NotificationRecord]

    /// Bucket `records` by Origin: miniApps first, alphabetical, then the
    /// orchestrator, the user, and anything unattributed. Empty buckets are
    /// dropped. `resolve` supplies a miniApp's display bits; nil means it was
    /// deleted since scheduling.
    static func grouped(
        _ records: [NotificationRecord],
        resolve: (UUID) -> (name: String, icon: String, tint: Color)?
    ) -> [NotificationOriginGroup] {
        var byMiniApp: [UUID: [NotificationRecord]] = [:]
        var orchestrator: [NotificationRecord] = []
        var user: [NotificationRecord] = []
        var unknown: [NotificationRecord] = []
        for r in records {
            switch r.origin {
            case .miniApp(let id): byMiniApp[id, default: []].append(r)
            case .orchestrator: orchestrator.append(r)
            case .user: user.append(r)
            case .unknown: unknown.append(r)
            }
        }

        var groups = byMiniApp.map { id, rows -> NotificationOriginGroup in
            let app = resolve(id)
            return NotificationOriginGroup(
                id: id.uuidString,
                title: app?.name ?? "Deleted app",
                icon: app?.icon ?? "questionmark.app.dashed",
                tint: app?.tint,
                rows: rows
            )
        }
        // Two miniApps can share a name, and `sort` isn't stable — without the
        // id tiebreak equal-titled sections swap places between redraws.
        groups.sort {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }

        if !orchestrator.isEmpty {
            groups.append(.init(
                id: "orchestrator", title: "Orchestrator", icon: "sparkles",
                tint: nil, rows: orchestrator
            ))
        }
        if !user.isEmpty {
            groups.append(.init(
                id: "user", title: "You", icon: "person", tint: nil, rows: user
            ))
        }
        if !unknown.isEmpty {
            groups.append(.init(
                id: "unknown", title: "Unattributed", icon: "questionmark.circle",
                tint: nil, rows: unknown
            ))
        }
        return groups
    }
}
