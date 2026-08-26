import Foundation
import PupaScripting

/// Launch-argument seam for driving a **launched** app — UI tests, or a demo
/// run you want reproducible.
///
///     -PupaStorageRoot /tmp/ui   isolate storage (required by every other flag)
///     -PupaStorageRoot ephemeral a fresh dir in the app's own temp — what a
///                                UI test uses, since the runner and the app
///                                don't share a sandbox
///     -PupaStorageRoot ephemeral:books
///                                the *same* dir every launch, so a terminate
///                                + relaunch lands back in it
///     -PupaStorageReset 1        wipe that dir first — launch 1 of a case
///     -PupaBackendURL  http://…  point the agent somewhere
///     -PupaHarness     claude_code  pick the backend agent harness
///     -PupaBackendToken tok      reach a paired backend without the Keychain
///     -PupaScript      path.jsonl  serve a canned backend, no network
///     -PupaSkipOnboarding 1      skip first-run
///     -PupaBackgroundGrace 2     shrink the iOS stream keep-alive hold
///     -PupaReattachAttempts 1    shrink the dropped-stream retry budget
///     -PupaReattachDelayMs 50    shrink its backoff
///
/// `PUPA_SCRIPT` in the environment carries a script inline instead of by
/// path — the only form that survives the sandbox boundary in a UI test.
/// `PUPA_BACKEND_TOKEN` carries the token the same way, and keeps it out of
/// the process list.
///
/// Inert with no arguments, so a normal launch is untouched. Every flag except
/// `-PupaStorageRoot` is ignored without it: nothing here may run against real
/// app data, the same rule `PerfFixture` enforces.
public enum LaunchOptions {
    /// Parsed once at launch. `RootView` reads it; nothing else should.
    public static let current = LaunchOptions.parse()

    public struct Values: Sendable {
        public var storageRoot: URL?
        public var resetStorage = false
        public var backendURL: URL?
        public var harnessID: String?
        public var backendToken: String?
        public var scriptPath: String?
        public var skipOnboarding = false
        /// Seconds to hold the iOS background task before releasing it. The
        /// simulator never fires the real expiry, so this is the only way to
        /// exercise a background long enough to lose the socket.
        public var backgroundGrace: TimeInterval?
        public var reattachAttempts: Int?
        public var reattachDelayNanos: UInt64?

        /// True when the app was launched to be driven rather than used.
        public var isDriven: Bool { storageRoot != nil }
    }

    /// Apply whatever was asked for. Call before any store is built —
    /// `PupaStorage.overrideRoot` has to be in place first.
    ///
    /// Returns the values it applied so a caller can branch on them.
    @discardableResult
    public static func apply() -> Values {
        let values = current
        guard let root = values.storageRoot else { return values }
        // A sticky root outlives the launch that made it, so a case that wants
        // a clean slate has to say so.
        if values.resetStorage { try? FileManager.default.removeItem(at: root) }
        PupaStorage.overrideRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let inline = ProcessInfo.processInfo.environment["PUPA_SCRIPT"] {
            ScriptedTransport.script = try? Script.parse(inline)
        } else if let path = values.scriptPath {
            ScriptedTransport.script = try? Script.load(URL(fileURLWithPath: path))
        }
        if values.skipOnboarding {
            UserDefaults.standard.set(true, forKey: OnboardingKeys.completed)
        }
        return values
    }

    /// Whether the app should serve its backend from a script rather than the
    /// network. Read by `URLSession.forBackend`.
    public static var isScripted: Bool {
        guard current.storageRoot != nil else { return false }
        return current.scriptPath != nil
            || ProcessInfo.processInfo.environment["PUPA_SCRIPT"] != nil
    }

    static func parse(_ arguments: [String] = CommandLine.arguments) -> Values {
        var values = Values()
        var rest = arguments.dropFirst()[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            func next() -> String? {
                guard let value = rest.first, !value.hasPrefix("-") else { return nil }
                rest = rest.dropFirst()
                return value
            }
            switch argument {
            case "-PupaStorageRoot": values.storageRoot = next().map(Self.resolveRoot)
            case "-PupaStorageReset": values.resetStorage = next() != "0"
            case "-PupaBackendURL": values.backendURL = next().flatMap(URL.init(string:))
            case "-PupaHarness": values.harnessID = next()
            case "-PupaBackendToken": values.backendToken = next()
            case "-PupaScript": values.scriptPath = next()
            case "-PupaSkipOnboarding": values.skipOnboarding = next() != "0"
            case "-PupaBackgroundGrace": values.backgroundGrace = next().flatMap(TimeInterval.init)
            case "-PupaReattachAttempts": values.reattachAttempts = next().flatMap(Int.init)
            case "-PupaReattachDelayMs":
                values.reattachDelayNanos = next().flatMap(UInt64.init).map { $0 * 1_000_000 }
            default: break
            }
        }
        // The rule the docstring states, enforced rather than assumed: without
        // a storage root none of this may reach a real launch. `apply()` alone
        // isn't enough — it returns early *with* the other values still set,
        // and `RootView` reads `backendURL` off that return.
        guard values.storageRoot != nil else { return Values() }
        // Env is the only channel that survives into a UI test's app process
        // without putting the token in the process list.
        if values.backendToken == nil {
            values.backendToken = ProcessInfo.processInfo.environment["PUPA_BACKEND_TOKEN"]
        }
        return values
    }

    /// `ephemeral` means "somewhere writable this launch owns" — a UI test
    /// can't hand over a path the app is allowed to read. `ephemeral:<name>`
    /// is the same dir every launch, which is what lets a test kill the app
    /// and relaunch it onto the state it left behind.
    private static func resolveRoot(_ raw: String) -> URL {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        if raw == "ephemeral" {
            return temp.appendingPathComponent("pupa-driven-\(UUID().uuidString)", isDirectory: true)
        }
        guard raw.hasPrefix("ephemeral:") else { return URL(fileURLWithPath: raw) }
        let name = String(raw.dropFirst("ephemeral:".count).map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
        })
        return temp.appendingPathComponent(
            "pupa-driven-\(name.isEmpty ? "sticky" : name)", isDirectory: true)
    }
}
