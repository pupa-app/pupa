import Foundation
import QuartzCore
import os

/// Interaction latency instrumentation. Off unless `PUPA_PERF=1`.
///
/// Two numbers per interaction, because either alone misleads:
/// - `main` — the runloop turn the tap kicks off (state write + SwiftUI body
///   + layout). Moves when synchronous work is removed from a `body`.
/// - `frame` — render-server ack for the resulting CoreAnimation commit.
///   Catches render-side cost (offscreen rasterization) that `main` misses.
///
/// Each line also carries `cold`/`warm`: first use of a name this launch is
/// cold, so "first open slow" is a column rather than an anecdote.
///
/// Output: one CSV line per number to `com.pupa-app.client`/`perf`, plus an
/// `os_signpost` interval so Instruments traces self-label on device.
public enum PerfTrace {
    /// A `let`, so `guard isEnabled` folds the bodies away when unset.
    public static let isEnabled = ProcessInfo.processInfo.environment["PUPA_PERF"] == "1"

    static let log = Logger(subsystem: "com.pupa-app.client", category: "perf")
    private static let signposter = OSSignposter(
        subsystem: "com.pupa-app.client", category: "perf")

    /// One recorded number. Collected only while tracing, so the PupaDemo
    /// harness can print a table without scraping the log.
    public struct Sample: Sendable {
        public let name: String
        public let phase: String
        public let kind: String
        public let ms: Double
    }

    /// Main-thread only (every writer is a main-queue callback), same
    /// single-threaded assumption as `DiskIO`.
    nonisolated(unsafe) public private(set) static var samples: [Sample] = []

    public static func resetSamples() { samples.removeAll() }

    /// Interaction names already timed this launch (cold/warm discriminator).
    @MainActor private static var seen: Set<String> = []

    /// Run `work` — a navigation state write — and record how long the UI
    /// takes to catch up. Transparent when disabled; `name` is an autoclosure
    /// so building it costs nothing on the shipping path.
    @MainActor
    public static func interaction(_ name: @autoclosure () -> String, _ work: () -> Void) {
        guard isEnabled else { work(); return }

        let name = name()
        let phase = seen.insert(name).inserted ? "cold" : "warm"
        let start = ContinuousClock.now
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval("interaction", id: signpostID)

        // Attach to the *implicit* transaction of this runloop turn — the one
        // SwiftUI will commit its update into — so the block fires on the
        // render-server ack. No begin/commit pair: an explicit transaction
        // would commit here, before SwiftUI has processed the state write.
        // Installed before `work()` so a nested explicit transaction inside
        // it can't swallow the callback.
        CATransaction.setCompletionBlock {
            signposter.endInterval("interaction", state)
            emit(name, phase, "frame", since: start)
        }

        work()

        // Drains after the current turn's body + layout, before the CA commit
        // completion — so `main` <= `frame`.
        DispatchQueue.main.async { emit(name, phase, "main", since: start) }
    }

    /// Time a synchronous span *inside* an interaction, to attribute its cost
    /// to a specific block rather than guess. Returns `work`'s value.
    @discardableResult
    public static func region<T>(_ name: String, _ work: () -> T) -> T {
        guard isEnabled else { return work() }
        let start = ContinuousClock.now
        defer { emit(name, "span", "sync", since: start) }
        return work()
    }

    // MARK: - Driving

    /// Interactions the PupaDemo harness triggers without a tap. Gesture
    /// recognition was never the problem; the runloop turn the state write
    /// kicks off is, so the harness writes the state directly.
    public enum Drive: String, Sendable {
        case toggleSidebar, toggleChat, nextApp
    }

    static let driveNotification = Notification.Name("pupa.perf.drive")

    public static func post(_ drive: Drive) {
        NotificationCenter.default.post(name: driveNotification, object: drive.rawValue)
    }

    public static var drivePublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: driveNotification)
    }

    /// The command in `note`, or nil when tracing is off — so a shipping build
    /// ignores the channel even if something posts on it.
    public static func drive(from note: Notification) -> Drive? {
        guard isEnabled, let raw = note.object as? String else { return nil }
        return Drive(rawValue: raw)
    }

    /// Interaction name for a navigation target: case kind + short MyApp id.
    /// The id matters — "first switch to each app" must read as cold per app,
    /// not warm after the first one. Derived by reflection, so new cases need
    /// no upkeep here; only ever called behind `isEnabled`.
    public static func label(_ sel: SidebarSelection) -> String {
        let kind = String(describing: sel).prefix { $0 != "(" }
        guard let id = sel.myAppId else { return String(kind) }
        return "\(kind).\(id.uuidString.prefix(8))"
    }

    private static func emit(
        _ name: String, _ phase: String, _ kind: String, since start: ContinuousClock.Instant
    ) {
        // Both components: cold opens have measured over a second, and
        // `attoseconds` alone wraps at the 1s boundary.
        let elapsed = (ContinuousClock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        samples.append(Sample(name: name, phase: phase, kind: kind, ms: ms))
        log.notice("""
            \(name, privacy: .public),\(phase, privacy: .public),\
            \(kind, privacy: .public),\(ms, format: .fixed(precision: 1), privacy: .public)
            """)
    }
}
