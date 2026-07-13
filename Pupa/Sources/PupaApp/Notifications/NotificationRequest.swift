import Foundation
import AGUIKit

/// Value-type description of a notification the agent wants to schedule.
/// Built from the `sendNotification` tool args by `init(fromToolArgs:)` and
/// consumed by `NotificationCenterCoordinator.schedule(_:)`.
public struct NotificationRequest: Sendable, Hashable {
    public enum Trigger: Sendable, Hashable {
        /// Fire as soon as the OS will allow. Maps to a `UNTimeIntervalNotificationTrigger`
        /// with a tiny epsilon (iOS rejects `timeInterval == 0`).
        case now
        /// Fire `seconds` seconds from when the system accepts the request.
        case after(seconds: Int)
        /// Fire at the given absolute wall-clock instant.
        case atDate(Date)
        /// Repeat every day at `hour`:`minute` (local time).
        case daily(hour: Int, minute: Int)
        /// Repeat weekly on `weekday` at `hour`:`minute`. `weekday` is
        /// `Calendar`-indexed: 1=Sunday … 7=Saturday.
        case weekly(weekday: Int, hour: Int, minute: Int)
        /// Repeat every N hours (1..24).
        case everyNHours(Int)

        /// Whether the OS trigger repeats. The three recurring presets do; the
        /// one-shot triggers (`now`/`after`/`atDate`) do not.
        public var repeats: Bool {
            switch self {
            case .now, .after, .atDate: return false
            case .daily, .weekly, .everyNHours: return true
            }
        }
    }

    /// What tapping the delivered banner does, beyond the OS bringing the app
    /// forward. `.foreground` is the historical default (no extra routing).
    public enum TapAction: Sendable, Hashable {
        /// Just foreground the app (plus any `target` deep-link navigation).
        case foreground
        /// Pre-fill the chat composer with `prompt` so the user can continue.
        case populateChat(prompt: String)
        /// Send `prompt` as an agent turn on the active chat scope on tap.
        case runAgent(prompt: String)
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missingField(String)
        case invalidTrigger(String)
        case titleTooLong(Int)
        case bodyTooLong(Int)
        case secondsOutOfRange(Int)
        case unparseableDate(String)
        case pastDate(String)
        case hourOutOfRange(Int)
        case minuteOutOfRange(Int)
        case weekdayOutOfRange(Int)
        case hoursOutOfRange(Int)
        case tapPromptTooLong(Int)
        case invalidTapAction(String)

        public var description: String {
            switch self {
            case .missingField(let f): return "missing '\(f)'"
            case .invalidTrigger(let m): return "invalid trigger: \(m)"
            case .titleTooLong(let n): return "title too long (\(n) > 64 chars)"
            case .bodyTooLong(let n): return "body too long (\(n) > 256 chars)"
            case .secondsOutOfRange(let s): return "seconds=\(s) out of range (1..31536000)"
            case .unparseableDate(let s): return "could not parse '\(s)' as ISO-8601"
            case .pastDate(let s): return "atDate '\(s)' is in the past"
            case .hourOutOfRange(let h): return "hour=\(h) out of range (0..23)"
            case .minuteOutOfRange(let m): return "minute=\(m) out of range (0..59)"
            case .weekdayOutOfRange(let w): return "weekday=\(w) out of range (1..7, Sun=1)"
            case .hoursOutOfRange(let h): return "hours=\(h) out of range (1..24)"
            case .tapPromptTooLong(let n): return "tapAction.prompt too long (\(n) > 256 chars)"
            case .invalidTapAction(let m): return "invalid tapAction: \(m)"
            }
        }
    }

    /// Optional deep-link target. When present, tapping the notification banner
    /// navigates the app to the specified myApp (and optionally component).
    public struct Target: Sendable, Hashable {
        public let myAppId: UUID
        /// Component to focus, e.g. `"tracker-1"`. Nil opens the myApp home.
        public let componentId: String?

        public init(myAppId: UUID, componentId: String? = nil) {
            self.myAppId = myAppId
            self.componentId = componentId
        }
    }

    public static let titleMaxLength = 64
    public static let bodyMaxLength = 256
    public static let tapPromptMaxLength = 256
    public static let secondsRange = 1...31_536_000
    public static let hourRange = 0...23
    public static let minuteRange = 0...59
    public static let weekdayRange = 1...7
    public static let everyNHoursRange = 1...24

    public let title: String
    public let body: String
    public let trigger: Trigger
    /// Where to navigate when the user taps the notification banner.
    /// Nil means tapping just foregrounds the app with no extra routing.
    public let target: Target?
    /// What tapping the banner does beyond foregrounding. `.foreground` by
    /// default (historical behaviour).
    public let tapAction: TapAction

    public init(
        title: String,
        body: String,
        trigger: Trigger,
        target: Target? = nil,
        tapAction: TapAction = .foreground
    ) {
        self.title = title
        self.body = body
        self.trigger = trigger
        self.target = target
        self.tapAction = tapAction
    }

    /// Build from the raw `AnyJSON` the tool registry hands us, or throw a
    /// `ParseError` describing what's wrong. Callers map the error
    /// description into the tool's `{ok: false, error: ...}` echo.
    public init(fromToolArgs args: AnyJSON, now: Date = Date()) throws {
        guard let title = args["title"]?.stringValue, !title.isEmpty else {
            throw ParseError.missingField("title")
        }
        if title.count > Self.titleMaxLength { throw ParseError.titleTooLong(title.count) }

        guard let body = args["body"]?.stringValue, !body.isEmpty else {
            throw ParseError.missingField("body")
        }
        if body.count > Self.bodyMaxLength { throw ParseError.bodyTooLong(body.count) }

        guard let trigger = args["trigger"], case .object = trigger else {
            throw ParseError.missingField("trigger")
        }
        guard let kind = trigger["kind"]?.stringValue else {
            throw ParseError.invalidTrigger("missing 'kind'")
        }

        let parsedTrigger: Trigger
        switch kind {
        case "now":
            parsedTrigger = .now
        case "after":
            guard let seconds = trigger["seconds"]?.intValue else {
                throw ParseError.invalidTrigger("'after' requires integer 'seconds'")
            }
            if !Self.secondsRange.contains(seconds) {
                throw ParseError.secondsOutOfRange(seconds)
            }
            parsedTrigger = .after(seconds: seconds)
        case "atDate":
            guard let iso = trigger["iso8601"]?.stringValue else {
                throw ParseError.invalidTrigger("'atDate' requires 'iso8601'")
            }
            guard let date = Self.parseISO8601(iso) else {
                throw ParseError.unparseableDate(iso)
            }
            if date <= now {
                throw ParseError.pastDate(iso)
            }
            parsedTrigger = .atDate(date)
        case "daily":
            let hour = try Self.requiredInt(trigger, "hour", kind: "daily")
            let minute = try Self.requiredInt(trigger, "minute", kind: "daily")
            guard Self.hourRange.contains(hour) else { throw ParseError.hourOutOfRange(hour) }
            guard Self.minuteRange.contains(minute) else { throw ParseError.minuteOutOfRange(minute) }
            parsedTrigger = .daily(hour: hour, minute: minute)
        case "weekly":
            let weekday = try Self.requiredInt(trigger, "weekday", kind: "weekly")
            let hour = try Self.requiredInt(trigger, "hour", kind: "weekly")
            let minute = try Self.requiredInt(trigger, "minute", kind: "weekly")
            guard Self.weekdayRange.contains(weekday) else { throw ParseError.weekdayOutOfRange(weekday) }
            guard Self.hourRange.contains(hour) else { throw ParseError.hourOutOfRange(hour) }
            guard Self.minuteRange.contains(minute) else { throw ParseError.minuteOutOfRange(minute) }
            parsedTrigger = .weekly(weekday: weekday, hour: hour, minute: minute)
        case "everyNHours":
            let hours = try Self.requiredInt(trigger, "hours", kind: "everyNHours")
            guard Self.everyNHoursRange.contains(hours) else { throw ParseError.hoursOutOfRange(hours) }
            parsedTrigger = .everyNHours(hours)
        default:
            throw ParseError.invalidTrigger(
                "unknown kind '\(kind)' (expected now / after / atDate / daily / weekly / everyNHours)"
            )
        }

        var target: Target? = nil
        if let targetArg = args["target"], case .object = targetArg,
           let idStr = targetArg["myAppId"]?.stringValue,
           let uuid = UUID(uuidString: idStr) {
            let componentId = targetArg["componentId"]?.stringValue
            target = Target(myAppId: uuid, componentId: componentId)
        }

        let tapAction = try Self.parseTapAction(args["tapAction"])

        self.init(
            title: title,
            body: body,
            trigger: parsedTrigger,
            target: target,
            tapAction: tapAction
        )
    }

    /// Read a required integer field off a trigger object, or throw an
    /// `invalidTrigger` naming the offending `kind`/`key`.
    private static func requiredInt(_ obj: AnyJSON, _ key: String, kind: String) throws -> Int {
        guard let value = obj[key]?.intValue else {
            throw ParseError.invalidTrigger("'\(kind)' requires integer '\(key)'")
        }
        return value
    }

    /// Parse the optional `tapAction:{kind, prompt}` object. Absent ⇒
    /// `.foreground`. `populateChat`/`runAgent` require a non-empty,
    /// length-capped `prompt`.
    private static func parseTapAction(_ arg: AnyJSON?) throws -> TapAction {
        guard let arg, case .object = arg else { return .foreground }
        guard let kind = arg["kind"]?.stringValue else {
            throw ParseError.invalidTapAction("missing 'kind'")
        }
        switch kind {
        case "foreground":
            return .foreground
        case "populateChat", "runAgent":
            guard let prompt = arg["prompt"]?.stringValue, !prompt.isEmpty else {
                throw ParseError.invalidTapAction("'\(kind)' requires non-empty 'prompt'")
            }
            if prompt.count > Self.tapPromptMaxLength {
                throw ParseError.tapPromptTooLong(prompt.count)
            }
            return kind == "populateChat" ? .populateChat(prompt: prompt) : .runAgent(prompt: prompt)
        default:
            throw ParseError.invalidTapAction(
                "unknown kind '\(kind)' (expected foreground / populateChat / runAgent)"
            )
        }
    }

    /// Compute the delivery instant the user will see in the echo payload.
    /// `.now` resolves to ~100 ms after `referenceDate` (matches the
    /// coordinator's epsilon) so the agent's `deliveryAt` matches reality.
    public func deliveryAt(referenceDate: Date = Date()) -> Date {
        switch trigger {
        case .now: return referenceDate.addingTimeInterval(0.1)
        case .after(let seconds): return referenceDate.addingTimeInterval(TimeInterval(seconds))
        case .atDate(let date): return date
        case .daily(let hour, let minute):
            let comps = DateComponents(hour: hour, minute: minute)
            return Calendar.current.nextDate(
                after: referenceDate, matching: comps, matchingPolicy: .nextTime
            ) ?? referenceDate
        case .weekly(let weekday, let hour, let minute):
            let comps = DateComponents(hour: hour, minute: minute, weekday: weekday)
            return Calendar.current.nextDate(
                after: referenceDate, matching: comps, matchingPolicy: .nextTime
            ) ?? referenceDate
        case .everyNHours(let hours):
            return referenceDate.addingTimeInterval(TimeInterval(hours * 3600))
        }
    }

    /// Mirror of the parsed trigger as a JSON object for the tool echo.
    public func triggerEcho() -> AnyJSON {
        switch trigger {
        case .now:
            return .object(["kind": .string("now")])
        case .after(let seconds):
            return .object(["kind": .string("after"), "seconds": .int(seconds)])
        case .atDate(let date):
            return .object([
                "kind": .string("atDate"),
                "iso8601": .string(Self.formatISO8601(date)),
            ])
        case .daily(let hour, let minute):
            return .object([
                "kind": .string("daily"),
                "hour": .int(hour),
                "minute": .int(minute),
            ])
        case .weekly(let weekday, let hour, let minute):
            return .object([
                "kind": .string("weekly"),
                "weekday": .int(weekday),
                "hour": .int(hour),
                "minute": .int(minute),
            ])
        case .everyNHours(let hours):
            return .object([
                "kind": .string("everyNHours"),
                "hours": .int(hours),
            ])
        }
    }

    /// Mirror of the parsed tap action as a JSON object for the tool echo.
    public func tapActionEcho() -> AnyJSON {
        switch tapAction {
        case .foreground:
            return .object(["kind": .string("foreground")])
        case .populateChat(let prompt):
            return .object(["kind": .string("populateChat"), "prompt": .string(prompt)])
        case .runAgent(let prompt):
            return .object(["kind": .string("runAgent"), "prompt": .string(prompt)])
        }
    }

    // MARK: - ISO-8601 helpers

    /// Parse an ISO-8601 string, accepting both fractional and second-precision.
    /// `ISO8601DateFormatter` is non-`Sendable`, so we allocate per call rather
    /// than caching — the cost is negligible compared to the agent round-trip.
    public static func parseISO8601(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: s)
    }

    public static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
