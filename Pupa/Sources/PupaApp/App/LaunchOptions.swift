import Foundation
import PupaScripting

/// Launch-argument seam for driving a **launched** app — UI tests, or a demo
/// run you want reproducible.
///
///     -PupaStorageRoot /tmp/ui   isolate storage (required by every other flag)
///     -PupaStorageRoot ephemeral a fresh dir in the app's own temp — what a
///                                UI test uses, since the runner and the app
///                                don't share a sandbox
///     -PupaBackendURL  http://…  point the agent somewhere
///     -PupaScript      path.jsonl  serve a canned backend, no network
///     -PupaSkipOnboarding 1      skip first-run
///
/// `PUPA_SCRIPT` in the environment carries a script inline instead of by
/// path — the only form that survives the sandbox boundary in a UI test.
///
/// Inert with no arguments, so a normal launch is untouched. Every flag except
/// `-PupaStorageRoot` is ignored without it: nothing here may run against real
/// app data, the same rule `PerfFixture` enforces.
public enum LaunchOptions {
    /// Parsed once at launch. `RootView` reads it; nothing else should.
    public static let current = LaunchOptions.parse()

    public struct Values: Sendable {
        public var storageRoot: URL?
        public var backendURL: URL?
        public var scriptPath: String?
        public var skipOnboarding = false

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
            case "-PupaBackendURL": values.backendURL = next().flatMap(URL.init(string:))
            case "-PupaScript": values.scriptPath = next()
            case "-PupaSkipOnboarding": values.skipOnboarding = next() != "0"
            default: break
            }
        }
        return values
    }

    /// `ephemeral` means "somewhere writable this launch owns" — a UI test
    /// can't hand over a path the app is allowed to read.
    private static func resolveRoot(_ raw: String) -> URL {
        guard raw == "ephemeral" else { return URL(fileURLWithPath: raw) }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-driven-\(UUID().uuidString)", isDirectory: true)
    }
}
