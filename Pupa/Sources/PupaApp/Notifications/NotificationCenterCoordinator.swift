import Foundation
import UserNotifications

/// Singleton wrapper around `UNUserNotificationCenter`. Owns:
///
/// - Lazy permission request (`requestAuthorizationIfNeeded`) — the agent's
///   first `sendNotification` call drives it; the user is never prompted at
///   app launch.
/// - `schedule(_:)` — converts a `NotificationRequest` into a
///   `UNNotificationRequest` and adds it; returns the assigned identifier and
///   resolved delivery instant.
/// - `cancel(id:)` — idempotent; reports whether the id was actually pending.
/// - `UNUserNotificationCenterDelegate` — presents banners while the app is
///   foregrounded (otherwise the OS swallows them silently). Tap behaviour is
///   intentionally minimal: the OS already brings the app forward; we do not
///   dispatch any agent prompt or sidebar switch here (that's #33 territory).
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

    /// Schedule `request`. Throws `.notAuthorised` if permission isn't
    /// granted (the caller has already lazily prompted via
    /// `requestAuthorizationIfNeeded`). Returns the identifier we assigned
    /// and the resolved delivery instant the agent can echo back to the user.
    public func schedule(_ request: NotificationRequest) async throws -> ScheduledNotification {
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
        case .atDate(let date):
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        }

        let id = UUID().uuidString
        let unRequest = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(unRequest)
        } catch {
            throw ScheduleError.underlying(error.localizedDescription)
        }
        return ScheduledNotification(
            id: id,
            deliveryAt: request.deliveryAt(referenceDate: referenceDate)
        )
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
        }
        return wasPending
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
        // Tap → OS already foregrounds the app. We do nothing else here:
        // agent re-entry on tap belongs to issue #33.
        completionHandler()
    }
}
