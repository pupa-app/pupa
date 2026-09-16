import Foundation
import SwiftUI
import Testing
@testable import PupaApp

@MainActor
@Suite("NotificationOriginGroup")
struct NotificationOriginGroupTests {
    private func record(_ origin: NotificationOrigin, _ unId: String) -> NotificationRecord {
        NotificationRecord(
            scheduling: NotificationRequest(title: "t", body: "b", trigger: .now),
            origin: origin, unId: unId, deliveryAt: Date()
        )
    }

    private func grouped(
        _ records: [NotificationRecord],
        names: [UUID: String] = [:]
    ) -> [NotificationOriginGroup] {
        NotificationOriginGroup.grouped(records) { id in
            names[id].map { ($0, "app.dashed", Color.blue) }
        }
    }

    @Test("miniApps come first alphabetically, then orchestrator, user, unattributed")
    func sectionOrder() {
        let zebra = UUID()
        let apple = UUID()
        let groups = grouped(
            [
                record(.unknown, "1"),
                record(.user, "2"),
                record(.miniApp(zebra), "3"),
                record(.orchestrator, "4"),
                record(.miniApp(apple), "5"),
            ],
            names: [zebra: "Zebra", apple: "Apple"]
        )

        #expect(groups.map(\.title) == ["Apple", "Zebra", "Orchestrator", "You", "Unattributed"])
    }

    @Test("empty buckets are dropped")
    func dropsEmptyBuckets() {
        let groups = grouped([record(.user, "1")])
        #expect(groups.map(\.title) == ["You"])
    }

    @Test("a miniApp deleted since scheduling keeps its own section")
    func deletedMiniAppKeepsSection() {
        let gone = UUID()
        let groups = grouped([record(.miniApp(gone), "1")])

        #expect(groups.count == 1)
        #expect(groups[0].title == "Deleted app")
        #expect(groups[0].id == gone.uuidString)
        #expect(groups[0].tint == nil)
    }

    @Test("several notifications from one miniApp share a section")
    func oneSectionPerMiniApp() {
        let id = UUID()
        let groups = grouped(
            [record(.miniApp(id), "1"), record(.miniApp(id), "2")], names: [id: "Tracker"]
        )

        #expect(groups.count == 1)
        #expect(groups[0].rows.count == 2)
    }
}
