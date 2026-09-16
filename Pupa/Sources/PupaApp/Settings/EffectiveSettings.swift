import Foundation

// MARK: - Scope

/// The granularity at which a setting value can be stored or resolved.
///
/// Resolution order (most-specific wins):
///   `component → miniApp → global → defaultValue`
public enum SettingsScope: Hashable, Sendable {
    case global
    case miniApp(UUID)
    case component(miniAppId: UUID, componentId: String)
}

// MARK: - SettingsKey

/// Type-safe key that names a single logical setting, its type, its default,
/// and the narrowest scope at which it is meaningful.
///
/// `lowestSupportedScope` prevents nonsensical keys: a setting that only
/// makes sense globally rejects per-miniApp overrides at the resolver level.
/// The ordering is: `.global` < `.miniApp` < `.component` (global is widest).
public protocol SettingsKey: Sendable {
    associatedtype Value: Sendable & Codable
    /// Stable snake_case name used as the JSON dictionary key in `MiniApp.settings`.
    static var name: String { get }
    static var defaultValue: Value { get }
    /// The narrowest scope this key supports. Resolving at a finer scope than
    /// this is a programming error — the resolver returns `defaultValue` and
    /// asserts in debug builds.
    static var lowestSupportedScope: SettingsScopeLevel { get }
}

/// Ordered granularity levels — used by `lowestSupportedScope` comparisons.
public enum SettingsScopeLevel: Int, Comparable, Sendable {
    case global = 0
    case miniApp = 1
    case component = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ scope: SettingsScope) {
        switch scope {
        case .global: self = .global
        case .miniApp: self = .miniApp
        case .component: self = .component
        }
    }
}

// MARK: - SettingValue (type-erased storage)

/// Serialisable wrapper used to store arbitrary setting values in
/// `MiniApp.settings: [String: SettingValue]` without losing type safety
/// at the resolver layer.
///
/// Only the types we actually use today are represented; extend the enum
/// when a new `SettingsKey.Value` type is needed.
public enum SettingValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case string(String)
    case int(Int)
    case double(Double)
    case stringArray([String])

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "bool":        self = .bool(try c.decode(Bool.self, forKey: .value))
        case "string":      self = .string(try c.decode(String.self, forKey: .value))
        case "int":         self = .int(try c.decode(Int.self, forKey: .value))
        case "double":      self = .double(try c.decode(Double.self, forKey: .value))
        case "stringArray": self = .stringArray(try c.decode([String].self, forKey: .value))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                   debugDescription: "Unknown SettingValue type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):        try c.encode("bool",        forKey: .type); try c.encode(v, forKey: .value)
        case .string(let v):      try c.encode("string",      forKey: .type); try c.encode(v, forKey: .value)
        case .int(let v):         try c.encode("int",         forKey: .type); try c.encode(v, forKey: .value)
        case .double(let v):      try c.encode("double",      forKey: .type); try c.encode(v, forKey: .value)
        case .stringArray(let v): try c.encode("stringArray", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - EffectiveSettings

/// Resolves a `SettingsKey` at a requested scope by walking from
/// most-specific to least-specific, stopping at the first layer that has
/// a value, and falling back to `defaultValue`.
///
/// **Sources (in resolution order):**
/// 1. Component layer — reserved; no concrete component-level keys in this phase.
/// 2. MiniApp layer — `miniAppSettings[miniAppId]?[key.name]` (a `[String: SettingValue]`
///    persisted inside `MiniApp.settings`).
/// 3. Global layer — `SettingsStore`'s strongly-typed properties.
/// 4. `SettingsKey.defaultValue` — always present.
///
/// `EffectiveSettings` is a value type and is cheap to construct per-call.
/// `ChatSessionCoordinator` builds one inline; there is no shared singleton.
public struct EffectiveSettings: Sendable {

    // MARK: Construction

    /// `globalSource` is the typed accessor bag for global-scope values.
    /// `miniAppSettings` maps each miniApp UUID to its raw override dictionary.
    public init(
        globalSource: GlobalSettingsSource,
        miniAppSettings: [UUID: [String: SettingValue]]
    ) {
        self.globalSource = globalSource
        self.miniAppSettings = miniAppSettings
    }

    // MARK: Resolution

    /// Resolve `key` at the requested `scope`.
    ///
    /// - If `scope` is finer than `key.lowestSupportedScope`, returns
    ///   `defaultValue` (and asserts in DEBUG).
    /// - Otherwise walks component → miniApp → global → default.
    public func resolve<K: SettingsKey>(_ key: K.Type, at scope: SettingsScope) -> K.Value {
        let requested = SettingsScopeLevel(scope)
        guard requested <= K.lowestSupportedScope || K.lowestSupportedScope == .global
                || requested.rawValue >= K.lowestSupportedScope.rawValue else {
            assertionFailure("Resolving \(K.name) at scope \(scope) is below its lowestSupportedScope \(K.lowestSupportedScope)")
            return K.defaultValue
        }

        // Component layer (reserved — no concrete keys yet)
        if case .component(let miniAppId, _) = scope {
            // Fall through to miniApp layer
            if let value = miniAppValue(key, miniAppId: miniAppId) { return value }
            if let value = globalSource.value(for: key) { return value }
            return K.defaultValue
        }

        // MiniApp layer
        if case .miniApp(let miniAppId) = scope {
            if let value = miniAppValue(key, miniAppId: miniAppId) { return value }
            if let value = globalSource.value(for: key) { return value }
            return K.defaultValue
        }

        // Global layer
        if let value = globalSource.value(for: key) { return value }
        return K.defaultValue
    }

    // MARK: Private

    private let globalSource: GlobalSettingsSource
    private let miniAppSettings: [UUID: [String: SettingValue]]

    private func miniAppValue<K: SettingsKey>(_ key: K.Type, miniAppId: UUID) -> K.Value? {
        guard K.lowestSupportedScope >= .miniApp else { return nil }
        guard let raw = miniAppSettings[miniAppId]?[K.name] else { return nil }
        return K.extract(raw)
    }
}

// MARK: - GlobalSettingsSource

/// Value-type snapshot of global-layer settings, captured at call time.
/// Build one inside a `@MainActor` context from a live `SettingsStore`;
/// pass it into `EffectiveSettings` which is non-isolated and `Sendable`.
public struct GlobalSettingsSource: Sendable {
    public let shellApprovalDisabled: Bool

    public init(shellApprovalDisabled: Bool) {
        self.shellApprovalDisabled = shellApprovalDisabled
    }

    func value<K: SettingsKey>(for key: K.Type) -> K.Value? {
        if K.self == ShellApprovalDisabledKey.self {
            return shellApprovalDisabled as? K.Value
        }
        return nil
    }
}

// MARK: - SettingsKey extraction helper

extension SettingsKey {
    /// Extract a typed value from a `SettingValue` enum case.
    /// Returns `nil` when the stored type doesn't match.
    static func extract(_ sv: SettingValue) -> Value? {
        switch sv {
        case .bool(let b)        where Value.self == Bool.self:     return b as? Value
        case .string(let s)      where Value.self == String.self:   return s as? Value
        case .int(let i)         where Value.self == Int.self:      return i as? Value
        case .double(let d)      where Value.self == Double.self:   return d as? Value
        case .stringArray(let a) where Value.self == [String].self: return a as? Value
        default: return nil
        }
    }
}

// MARK: - Concrete keys

/// Global + per-MiniApp toggle for `ShellApprovalMiddleware`.
/// `lowestSupportedScope = .miniApp` means it can be overridden per-MiniApp.
public enum ShellApprovalDisabledKey: SettingsKey {
    public typealias Value = Bool
    public static let name = "shell_approval_disabled"
    public static let defaultValue = false
    public static let lowestSupportedScope: SettingsScopeLevel = .miniApp
}
