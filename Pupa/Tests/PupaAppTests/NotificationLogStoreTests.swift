import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("NotificationLogStore", .serialized)
struct NotificationLogStoreTests {
    init() { TestStorage.activate() }

    private func freshStore() -> NotificationLogStore {
        NotificationLogStore.clearStorage()
        return NotificationLogStore()
    }

    private func request(
        _ title: String = "Stand up",
        trigger: NotificationRequest.Trigger = .after(seconds: 60)
    ) -> NotificationRequest {
        NotificationRequest(title: title, body: "body", trigger: trigger)
    }

    private func pending(
        _ id: String,
        deliveryAt: Date?,
        repeats: Bool = false,
        componentId: String? = nil,
        origin: String? = nil
    ) -> NotificationCenterCoordinator.PendingNotification {
        .init(
            id: id, title: "Stand up", body: "body",
            deliveryAt: deliveryAt, repeats: repeats,
            componentId: componentId, origin: origin
        )
    }

    // MARK: - Persistence

    @Test("a scheduled record round-trips to disk")
    func roundTrip() {
        let writer = freshStore()
        let myAppId = UUID()
        writer.noteScheduled(
            request(), origin: .myApp(myAppId),
            unId: "un-1", deliveryAt: Date(timeIntervalSince1970: 1_000)
        )

        let reader = NotificationLogStore()
        #expect(reader.records.count == 1)
        #expect(reader.records[0].unId == "un-1")
        #expect(reader.records[0].origin == .myApp(myAppId))
        #expect(reader.records[0].title == "Stand up")
        #expect(reader.records[0].status == .scheduled)
        #expect(reader.records[0].request?.trigger == .after(seconds: 60))
    }

    @Test("a deep link survives persistence, so an edit after relaunch keeps it")
    func routingSurvivesDisk() {
        let store = freshStore()
        let myAppId = UUID()
        store.noteScheduled(
            NotificationRequest(
                title: "Stand up", body: "body",
                trigger: .weekly(weekday: 3, hour: 8, minute: 15),
                target: .init(myAppId: myAppId, componentId: "tracker-1"),
                tapAction: .runAgent(prompt: "log it")
            ),
            origin: .myApp(myAppId), unId: "un-1", deliveryAt: Date()
        )

        // After a relaunch the composer seeds `preserving:` from the decoded
        // request — if Target or TapAction don't survive JSON, editing an
        // agent's reminder silently severs its route back into the myApp.
        let decoded = NotificationLogStore().records[0].request
        #expect(decoded?.target?.myAppId == myAppId)
        #expect(decoded?.target?.componentId == "tracker-1")
        #expect(decoded?.tapAction == .runAgent(prompt: "log it"))
        #expect(decoded?.trigger == .weekly(weekday: 3, hour: 8, minute: 15))
    }

    @Test("every Origin case survives a Codable round-trip")
    func originCodable() throws {
        let id = UUID()
        for origin in [
            NotificationOrigin.user, .orchestrator, .unknown, .myApp(id),
        ] {
            let data = try JSONEncoder().encode(origin)
            #expect(try JSONDecoder().decode(NotificationOrigin.self, from: data) == origin)
        }
    }

    @Test("the log stays out of the mirrored state/ subtree")
    func notMirrored() {
        let store = freshStore()
        store.noteScheduled(request(), origin: .user, unId: "un-1", deliveryAt: Date())
        let path = NotificationLogStore.url.path
        #expect(path.hasSuffix("notifications/log.json"))
        #expect(!path.contains("/state/"))
    }

    // MARK: - Reconcile

    @Test("a one-shot whose delivery instant has passed is marked fired")
    func firesPastOneShot() {
        let store = freshStore()
        let now = Date()
        store.noteScheduled(
            request(), origin: .user,
            unId: "un-1", deliveryAt: now.addingTimeInterval(-60),
            now: now.addingTimeInterval(-120)
        )

        store.reconcile(pending: [], capturedAt: now, now: now)

        #expect(store.records[0].status == .fired)
        #expect(store.records[0].statusChangedAt == now)
        // The row must report when it *fired*, not when the app noticed. iOS
        // gives no callback for an untapped delivery, so `statusChangedAt` is
        // just whenever we next reconciled — possibly days later.
        #expect(store.records[0].displayDate == now.addingTimeInterval(-60))
    }

    @Test("a one-shot still in the future that left the queue is marked cancelled")
    func cancelsFutureDisappearance() {
        let store = freshStore()
        let now = Date()
        store.noteScheduled(
            request(), origin: .user,
            unId: "un-1", deliveryAt: now.addingTimeInterval(600),
            now: now.addingTimeInterval(-60)
        )

        store.reconcile(pending: [], capturedAt: now, now: now)

        #expect(store.records[0].status == .cancelled)
        // A cancel happens in-app, so its status change *is* the event.
        #expect(store.records[0].displayDate == now)
    }

    @Test("a repeat still pending stays scheduled and refreshes its next date")
    func refreshesRepeat() {
        let store = freshStore()
        let now = Date()
        let first = now.addingTimeInterval(3_600)
        store.noteScheduled(
            request(trigger: .daily(hour: 9, minute: 0)), origin: .user,
            unId: "un-1", deliveryAt: first, now: now.addingTimeInterval(-60)
        )
        let next = first.addingTimeInterval(86_400)

        store.reconcile(
            pending: [pending("un-1", deliveryAt: next, repeats: true)], capturedAt: now, now: now
        )

        #expect(store.records[0].status == .scheduled)
        #expect(store.records[0].deliveryAt == next)
    }

    @Test("a pending request the log has never seen is adopted, origin from its marker")
    func adoptsOrphanWithMarker() {
        let store = freshStore()
        let myAppId = UUID()

        store.reconcile(
            pending: [
                pending(
                    "un-orphan", deliveryAt: Date().addingTimeInterval(60),
                    componentId: "tracker-1",
                    origin: NotificationOrigin.myApp(myAppId).userInfoValue
                )
            ],
            capturedAt: Date(), now: Date()
        )

        #expect(store.records.count == 1)
        #expect(store.records[0].origin == .myApp(myAppId))
        #expect(store.records[0].componentId == "tracker-1")
        // No trigger detail survives in the OS queue, so it can't be edited.
        #expect(store.records[0].request == nil)
        #expect(store.records[0].isEditable == false)
    }

    @Test("an orphan with no marker is Unattributed, not credited to the user")
    func adoptsUnattributedOrphan() {
        let store = freshStore()

        store.reconcile(pending: [pending("un-old", deliveryAt: Date())], capturedAt: Date(), now: Date())

        #expect(store.records[0].origin == .unknown)
    }

    @Test("a malformed origin marker adopts as Unattributed, not as a bogus myApp")
    func adoptsMalformedMarker() {
        let store = freshStore()

        store.reconcile(
            pending: [pending("un-bad", deliveryAt: Date(), origin: "myApp:not-a-uuid")],
            capturedAt: Date(), now: Date()
        )

        #expect(store.records[0].origin == .unknown)
    }

    @Test("a cancelled record still in the queue is not re-adopted as a second row")
    func doesNotReadoptCancelled() {
        let store = freshStore()
        let now = Date()
        store.noteScheduled(
            request(), origin: .user, unId: "un-1",
            deliveryAt: now.addingTimeInterval(600), now: now.addingTimeInterval(-60)
        )
        store.markCancelled(unId: "un-1", now: now)

        // A snapshot taken before the cancel still lists it.
        store.reconcile(
            pending: [pending("un-1", deliveryAt: now.addingTimeInterval(600))],
            capturedAt: now, now: now
        )

        #expect(store.records.count == 1)
        #expect(store.records[0].status == .cancelled)
    }

    @Test("the identifier an edit replaced is not adopted from a stale snapshot")
    func doesNotReadoptRetiredUnId() {
        let store = freshStore()
        let now = Date()
        store.noteScheduled(
            request(), origin: .user, unId: "un-old",
            deliveryAt: now.addingTimeInterval(600), now: now.addingTimeInterval(-60)
        )
        store.noteEdited(
            id: store.records[0].id, request: request("Retimed"),
            unId: "un-new", deliveryAt: now.addingTimeInterval(900),
            now: now.addingTimeInterval(-30)
        )

        // Snapshot captured before the edit landed: it still holds the old id.
        store.reconcile(
            pending: [pending("un-old", deliveryAt: now.addingTimeInterval(600))],
            capturedAt: now, now: now
        )

        #expect(store.records.count == 1)
        #expect(store.records[0].unId == "un-new")
    }

    @Test("a record scheduled after the queue snapshot is left alone, not cancelled")
    func ignoresRecordsNewerThanSnapshot() {
        let store = freshStore()
        let snapshotAt = Date()
        // Reading the queue is async; a schedule can land during the
        // suspension. Judging it against a snapshot that predates it would
        // mark a live notification cancelled, permanently.
        store.noteScheduled(
            request(), origin: .user, unId: "un-late",
            deliveryAt: snapshotAt.addingTimeInterval(600),
            now: snapshotAt.addingTimeInterval(1)
        )

        store.reconcile(pending: [], capturedAt: snapshotAt, now: snapshotAt)

        #expect(store.records[0].status == .scheduled)
    }

    @Test("a notification that fires during the queue read is fired, not cancelled")
    func firesDuringQueueRead() {
        let store = freshStore()
        let capturedAt = Date()
        let due = capturedAt.addingTimeInterval(0.5)
        store.noteScheduled(
            request(), origin: .user, unId: "un-1",
            deliveryAt: due, now: capturedAt.addingTimeInterval(-60)
        )

        // Absent from a snapshot taken just before it was due; by the time the
        // read returned, its instant had passed.
        store.reconcile(pending: [], capturedAt: capturedAt, now: due.addingTimeInterval(0.1))

        #expect(store.records[0].status == .fired)
    }

    @Test("records finished in one pass sort deterministically despite equal timestamps")
    func sortTieBreaksOnId() {
        let store = freshStore()
        let now = Date()
        for i in 0..<5 {
            store.noteScheduled(
                request("r-\(i)"), origin: .user, unId: "un-\(i)",
                deliveryAt: now.addingTimeInterval(600), now: now.addingTimeInterval(-60)
            )
        }
        // One pass stamps every row with the same instant.
        store.reconcile(pending: [], capturedAt: now, now: now)

        let first = store.records.sorted(by: NotificationRecord.byMostRecent).map(\.unId)
        let second = store.records.reversed().sorted(by: NotificationRecord.byMostRecent).map(\.unId)

        #expect(first == second)
    }

    @Test("reconcile is idempotent — a second pass with the same queue changes nothing")
    func reconcileIdempotent() {
        let store = freshStore()
        let now = Date()
        let queue = [pending("un-1", deliveryAt: now.addingTimeInterval(60))]

        store.reconcile(pending: queue, capturedAt: now, now: now)
        store.reconcile(pending: queue, capturedAt: now, now: now)

        #expect(store.records.count == 1)
    }

    // MARK: - Cancel / edit

    @Test("markCancelled finishes the matching record and leaves others alone")
    func marksCancelled() {
        let store = freshStore()
        store.noteScheduled(request(), origin: .user, unId: "un-1", deliveryAt: Date())
        store.noteScheduled(request(), origin: .user, unId: "un-2", deliveryAt: Date())

        store.markCancelled(unId: "un-1")

        #expect(store.records.first { $0.unId == "un-1" }?.status == .cancelled)
        #expect(store.records.first { $0.unId == "un-2" }?.status == .scheduled)
    }

    @Test("an edit keeps the record's id and Origin while the OS identifier churns")
    func editKeepsIdentity() {
        let store = freshStore()
        let myAppId = UUID()
        store.noteScheduled(
            request(), origin: .myApp(myAppId), unId: "un-1", deliveryAt: Date()
        )
        let recordId = store.records[0].id

        store.noteEdited(
            id: recordId,
            request: request("Retimed", trigger: .daily(hour: 7, minute: 30)),
            unId: "un-2",
            deliveryAt: Date().addingTimeInterval(3_600)
        )

        #expect(store.records.count == 1)
        #expect(store.records[0].id == recordId)
        #expect(store.records[0].unId == "un-2")
        #expect(store.records[0].origin == .myApp(myAppId))
        #expect(store.records[0].title == "Retimed")
        #expect(store.records[0].repeats)
        #expect(store.records[0].editedByUser)
    }

    @Test("editing your own reminder doesn't badge it as edited")
    func editingOwnReminderIsNotBadged() {
        let store = freshStore()
        store.noteScheduled(request(), origin: .user, unId: "un-1", deliveryAt: Date())

        store.noteEdited(
            id: store.records[0].id, request: request("Retimed"),
            unId: "un-2", deliveryAt: Date()
        )

        // The badge says "an agent set this, then you changed it". On a row
        // already filed under You it carries nothing.
        #expect(!store.records[0].editedByUser)
    }

    // MARK: - Retention

    @Test("the cap evicts the oldest finished records but never a scheduled one")
    func capSparesScheduled() {
        let store = freshStore()
        let base = Date(timeIntervalSince1970: 0)
        // One live record, then cap+10 fired ones with ascending finish times.
        store.noteScheduled(
            request(), origin: .user, unId: "live",
            deliveryAt: base.addingTimeInterval(1_000_000)
        )
        for i in 0..<(NotificationLogStore.cap + 10) {
            store.noteScheduled(
                request("fired-\(i)"), origin: .user, unId: "un-\(i)",
                deliveryAt: base.addingTimeInterval(Double(i))
            )
            store.markCancelled(unId: "un-\(i)", now: base.addingTimeInterval(Double(i)))
        }

        // The cap counts history only — a live row doesn't cost a history slot.
        #expect(store.records.count == NotificationLogStore.cap + 1)
        #expect(store.records.contains { $0.unId == "live" })
        // Oldest finished went first; the newest survived.
        #expect(!store.records.contains { $0.unId == "un-0" })
        #expect(store.records.contains { $0.unId == "un-\(NotificationLogStore.cap + 9)" })
    }

    @Test("deleteFromHistory removes a finished row and refuses a scheduled one")
    func deleteFromHistoryGuardsActive() {
        let store = freshStore()
        store.noteScheduled(request(), origin: .user, unId: "live", deliveryAt: Date())
        store.noteScheduled(request(), origin: .user, unId: "done", deliveryAt: Date())
        store.markCancelled(unId: "done")
        let live = store.records.first { $0.unId == "live" }!
        let done = store.records.first { $0.unId == "done" }!

        // Deleting a scheduled row would orphan a notification the OS will
        // still fire, with no way left to cancel it.
        store.deleteFromHistory(id: live.id)
        #expect(store.records.contains { $0.unId == "live" })

        store.deleteFromHistory(id: done.id)
        #expect(!store.records.contains { $0.unId == "done" })
        #expect(NotificationLogStore().records.count == 1)
    }

    @Test("a batch finished in one pass evicts the oldest delivery, not an arbitrary one")
    func capEvictsByDeliveryNotNoticedAt() {
        let store = freshStore()
        let base = Date(timeIntervalSince1970: 0)
        let overflow = 20
        for i in 0..<(NotificationLogStore.cap + overflow) {
            store.noteScheduled(
                request("r-\(i)"), origin: .user, unId: "un-\(i)",
                deliveryAt: base.addingTimeInterval(Double(i)), now: base
            )
        }
        // All due, all noticed at once — every row gets the same
        // `statusChangedAt`, so only `deliveryAt` distinguishes them.
        let noticedAt = base.addingTimeInterval(1_000_000)
        store.reconcile(pending: [], capturedAt: noticedAt, now: noticedAt)

        #expect(store.records.count == NotificationLogStore.cap)
        // The most recent deliveries are the ones worth keeping.
        #expect(store.records.contains { $0.unId == "un-\(NotificationLogStore.cap + overflow - 1)" })
        #expect(!store.records.contains { $0.unId == "un-0" })
    }

    @Test("clearHistory drops finished records and keeps scheduled ones")
    func clearHistoryKeepsActive() {
        let store = freshStore()
        store.noteScheduled(request(), origin: .user, unId: "live", deliveryAt: Date())
        store.noteScheduled(request(), origin: .user, unId: "done", deliveryAt: Date())
        store.markCancelled(unId: "done")

        store.clearHistory()

        #expect(store.records.count == 1)
        #expect(store.records[0].unId == "live")
        #expect(NotificationLogStore().records.count == 1)
    }
}
