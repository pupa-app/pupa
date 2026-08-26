import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted (on Foundation's `NotificationCenter.default`) when the user taps
    /// a Pupa notification that carries a deep-link target. The `userInfo`
    /// dictionary contains a `SidebarSelection` under the key `"selection"`.
    public static let pupaNotificationTap = Notification.Name("pupa.notificationTap")
}

/// Singleton wrapper around `UNUserNotificationCenter`. Owns:
///
/// - Lazy permission request (`requestAuthorizationIfNeeded`) — the agent's
///   first `sendNotification` call drives it; the user is never prompted at
///   app launch.
/// - `schedule(_:origin:)` — converts a `NotificationRequest` into a
///   `UNNotificationRequest` and adds it; returns the assigned identifier and
///   resolved delivery instant.
/// - `cancel(id:)` — idempotent; reports whether the id was actually pending.
/// - `reschedule(...)` — an edit, i.e. schedule the replacement then drop the
///   original, since UN can't mutate a request.
/// - `log` (`NotificationLogStore`) — the durable record of all of the above.
///   The OS queue holds only pending requests, so `reconcileLog()` folds it
///   back in to notice what fired.
/// - `UNUserNotificationCenterDelegate` — presents banners while the app is
///   foregrounded (otherwise the OS swallows them silently). On tap it routes
///   the notification's deep-link target and/or `tapAction` (populate the
///   chat composer / run an agent turn) by buffering into `pendingTap` and
///   posting `.pupaNotificationTap` for `AppView` to consume.
///
/// Bootstrapped once at app startup via `bootstrap()`. After that, all
/// callers go through `shared`.
@MainActor
public final class NotificationCenterCoordinator: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationCenterCoordinator()

    public enum AuthState: Sendable, Hashable {
        case authorised
        case denied
        case notDetermined
        case provisional
    }

    public struct ScheduledNotification: Sendable, Hashable {
        public let id: String
        public let deliveryAt: Date
    }

    /// A pending (scheduled-but-not-yet-delivered) notification, flattened to
    /// the fields the Settings list shows. `deliveryAt` is `nil` only for
    /// trigger types we don't construct (defensive — every `schedule(_:)`
    /// trigger resolves a date).
    public struct PendingNotification: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let body: String
        public let deliveryAt: Date?
        /// Whether the underlying OS trigger repeats (recurring preset).
        public let repeats: Bool
        /// Component the banner deep-links to, from the notification's
        /// userInfo. Nil when it was scheduled without one.
        public let componentId: String?
        /// Raw `pupa.origin` marker, for rebuilding a `NotificationRecord`
        /// from the queue alone — see `NotificationRecord.init(adopting:)`.
        public let origin: String?
    }

    public enum ScheduleError: Error, CustomStringConvertible {
        case notAuthorised
        case unsupportedHost
        case underlying(String)

        public var description: String {
            switch self {
            case .notAuthorised: return "notifications-not-authorized"
            case .unsupportedHost: return "notifications-unsupported-host"
            case .underlying(let s): return s
            }
        }
    }

    /// `UNUserNotificationCenter.current()` raises an Obj-C exception in
    /// processes without an `NSBundleIdentifier` — true for the unsigned
    /// `swift run PupaDemo` macOS binary AND for the SwiftPM unit-test
    /// host. Detect that up-front; when false, `bootstrap()` no-ops and the
    /// tools echo `notifications-unsupported-host` so the agent can tell the
    /// user to switch to the Xcode target.
    public static var isHostSupported: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private var didBootstrap = false
    /// Resolved lazily AND only when `isHostSupported` — otherwise touching
    /// this lazy var crashes the process.
    private lazy var center: UNUserNotificationCenter = .current()

    /// One-slot buffer for a tap that arrives before `AppView` subscribes to
    /// `.pupaNotificationTap` (cold launch: `didReceive` can fire before
    /// `body`'s `.onReceive` is installed, and Foundation's `NotificationCenter`
    /// does not buffer). `AppView` drains this on appear. Keys match the posted
    /// userInfo (`selection` / `tapAction` / `tapPrompt`).
    public var pendingTap: [String: Any]?

    /// Durable record of what was scheduled and what became of it. The OS
    /// queue is not a history; this is. Read lazily rather than held, so its
    /// file isn't decoded on the launch path.
    private var log: NotificationLogStore { .shared }

    private override init() {
        super.init()
    }

    /// Idempotent. Installs the delegate so foreground banners actually
    /// surface. Call once from the app entry (`AppView.init` or the demo
    /// `App` struct). No-ops in hosts without a bundle identifier (unsigned
    /// `swift run` macOS binaries, SwiftPM test process).
    public func bootstrap() {
        guard !didBootstrap, Self.isHostSupported else { return }
        didBootstrap = true
        center.delegate = self
    }

    /// Ask the user for `[.alert, .sound]` if we haven't already. Returns the
    /// resulting state; callers map `denied` / `notDetermined` to the
    /// `notifications-not-authorized` tool echo.
    public func requestAuthorizationIfNeeded() async -> AuthState {
        guard Self.isHostSupported else { return .denied }
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized: return .authorised
        case .provisional, .ephemeral: return .provisional
        case .denied: return .denied
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                return granted ? .authorised : .denied
            } catch {
                return .denied
            }
        @unknown default:
            return .denied
        }
    }

    /// Schedule `request` on behalf of `origin`. Throws `.notAuthorised` if
    /// permission isn't granted (the caller has already lazily prompted via
    /// `requestAuthorizationIfNeeded`). Returns the identifier we assigned
    /// and the resolved delivery instant the agent can echo back to the user.
    ///
    /// Also writes a `NotificationRecord` to `log`, which is what survives
    /// delivery — the OS queue forgets a one-shot the moment it fires.
    /// `replacing` carries the record id when this call is the second half of
    /// an edit, so the log updates that row instead of appending a new one.
    public func schedule(
        _ request: NotificationRequest,
        origin: NotificationOrigin,
        replacing: UUID? = nil
    ) async throws -> ScheduledNotification {
        guard Self.isHostSupported else { throw ScheduleError.unsupportedHost }
        let auth = await requestAuthorizationIfNeeded()
        switch auth {
        case .authorised, .provisional: break
        case .denied, .notDetermined: throw ScheduleError.notAuthorised
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        // Stash the deep-link target and/or tap action in userInfo so the
        // delegate can route the tap (and the Settings list can label it).
        var info: [String: String] = ["pupa.origin": origin.userInfoValue]
        if let target = request.target {
            if let mid = target.myAppId { info["pupa.myAppId"] = mid.uuidString }
            if let cid = target.componentId { info["pupa.componentId"] = cid }
        }
        switch request.tapAction {
        case .foreground: break
        case .populateChat(let prompt):
            info["pupa.tapAction"] = "populateChat"
            info["pupa.tapPrompt"] = prompt
        case .runAgent(let prompt):
            info["pupa.tapAction"] = "runAgent"
            info["pupa.tapPrompt"] = prompt
        }
        content.userInfo = info

        let trigger: UNNotificationTrigger
        let referenceDate = Date()
        switch request.trigger {
        case .now:
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        case .after(let seconds):
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(seconds),
                repeats: false
            )
        case .atDate(let date) where date <= referenceDate:
            // A calendar match on an instant that has passed never fires and
            // has no next trigger date, so the record would sit `.scheduled`
            // until reconcile called it `.fired` — reporting a delivery that
            // never happened. Fire it now instead.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        case .atDate(let date):
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        case .daily(let hour, let minute):
            let comps = DateComponents(hour: hour, minute: minute)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        case .weekly(let weekday, let hour, let minute):
            let comps = DateComponents(hour: hour, minute: minute, weekday: weekday)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        case .everyNHours(let hours):
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(hours * 3600),
                repeats: true
            )
        }

        let id = UUID().uuidString
        let unRequest = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(unRequest)
        } catch {
            throw ScheduleError.underlying(error.localizedDescription)
        }
        // Resolve the delivery instant from the built trigger's next fire date
        // so recurring presets report their *next* occurrence; fall back to the
        // request's own computation defensively.
        let resolved = (trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            ?? (trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            ?? request.deliveryAt(referenceDate: referenceDate)
        switch replacing {
        case .none:
            log.noteScheduled(request, origin: origin, unId: id, deliveryAt: resolved)
        case .some(let recordId):
            log.noteEdited(id: recordId, request: request, unId: id, deliveryAt: resolved)
        }
        return ScheduledNotification(id: id, deliveryAt: resolved)
    }

    /// Replace a scheduled notification with an edited one, keeping the
    /// record's identity and Origin. UN can't mutate a request, so this is
    /// cancel + reschedule: the OS identifier necessarily changes, the record
    /// id doesn't.
    /// Schedules the replacement *first*: if that throws (permission revoked,
    /// OS refusal) the original is still in the queue and the user has lost
    /// nothing.
    public func reschedule(
        recordId: UUID,
        previousUnId: String,
        with request: NotificationRequest,
        origin: NotificationOrigin
    ) async throws -> ScheduledNotification {
        let scheduled = try await schedule(request, origin: origin, replacing: recordId)
        center.removePendingNotificationRequests(withIdentifiers: [previousUnId])
        return scheduled
    }

    /// Cancel a pending notification by identifier. Returns `true` if the id
    /// was actually pending (and is now removed), `false` if the id was
    /// unknown or already delivered. Always succeeds — cancellation is
    /// idempotent so the agent can fire-and-forget.
    public func cancel(id: String) async -> Bool {
        guard Self.isHostSupported else { return false }
        let pending = await center.pendingNotificationRequests()
        let wasPending = pending.contains { $0.identifier == id }
        if wasPending {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            // Only a request we actually pulled out of the queue was
            // cancelled. An id that already fired is left for `reconcileLog`
            // to mark `.fired` — logging it as cancelled would erase the very
            // distinction this exists to draw.
            log.markCancelled(unId: id)
        }
        return wasPending
    }

    /// Fold the OS queue into the log — notice what fired, refresh repeats,
    /// adopt anything scheduled before the log existed. Called on foreground
    /// and whenever the Notifications screen opens.
    public func reconcileLog() async {
        // On a host that can't read the queue, "nothing pending" is ignorance,
        // not fact — reconciling against it would mark every record fired.
        guard Self.isHostSupported else { return }
        // Two instants, because they answer opposite questions: `capturedAt`
        // predates the read, so a record written during it isn't judged
        // against a queue that predates it; `now` postdates the read, so a
        // notification that fired during it reads as delivered, not cancelled.
        let capturedAt = Date()
        let pending = await pendingNotifications()
        log.reconcile(pending: pending, capturedAt: capturedAt, now: Date())
    }

    /// The OS pending queue, flattened. Unordered — `reconcile` keys by id and
    /// the list sorts what it displays.
    private func pendingNotifications() async -> [PendingNotification] {
        await center.pendingNotificationRequests()
            .map { req in
                let deliveryAt: Date?
                let repeats: Bool
                switch req.trigger {
                case let trigger as UNCalendarNotificationTrigger:
                    deliveryAt = trigger.nextTriggerDate()
                    repeats = trigger.repeats
                case let trigger as UNTimeIntervalNotificationTrigger:
                    deliveryAt = trigger.nextTriggerDate()
                    repeats = trigger.repeats
                default:
                    deliveryAt = nil
                    repeats = false
                }
                let userInfo = req.content.userInfo
                return PendingNotification(
                    id: req.identifier,
                    title: req.content.title,
                    body: req.content.body,
                    deliveryAt: deliveryAt,
                    repeats: repeats,
                    componentId: userInfo["pupa.componentId"] as? String,
                    origin: userInfo["pupa.origin"] as? String
                )
            }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + play sound even while the app is foregrounded —
        // otherwise the OS swallows the alert and the agent's `now`-triggered
        // notification appears to do nothing.
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Read the Sendable primitives here (nonisolated), then hop to the main
        // actor once to build + buffer + broadcast the tap. Capturing only
        // strings keeps the hop Sendable-clean.
        let userInfo = response.notification.request.content.userInfo
        let myAppIdString = userInfo["pupa.myAppId"] as? String
        let componentId = userInfo["pupa.componentId"] as? String
        let tapAction = userInfo["pupa.tapAction"] as? String
        let tapPrompt = userInfo["pupa.tapPrompt"] as? String
        completionHandler()
        Task { @MainActor in
            self.deliverTap(
                myAppIdString: myAppIdString,
                componentId: componentId,
                tapAction: tapAction,
                tapPrompt: tapPrompt
            )
        }
    }

    /// Build the tap payload, park it in `pendingTap` (cold-launch drain), then
    /// post `.pupaNotificationTap` so a live `AppView` routes it immediately.
    /// Set-then-post ordering means the `.onReceive` handler always sees a
    /// non-nil buffer; whichever of `.onReceive` / `.onAppear` drains first
    /// clears it, so the action fires exactly once.
    @MainActor
    private func deliverTap(
        myAppIdString: String?,
        componentId: String?,
        tapAction: String?,
        tapPrompt: String?
    ) {
        var payload: [String: Any] = [:]
        if let s = myAppIdString, let id = UUID(uuidString: s) {
            payload["selection"] = componentId.map { SidebarSelection.myAppComponent(id, $0) }
                ?? .myApp(id)
        }
        if let tapAction {
            payload["tapAction"] = tapAction
            payload["tapPrompt"] = tapPrompt ?? ""
        }
        guard !payload.isEmpty else { return }
        pendingTap = payload
        NotificationCenter.default.post(name: .pupaNotificationTap, object: nil)
    }
}
