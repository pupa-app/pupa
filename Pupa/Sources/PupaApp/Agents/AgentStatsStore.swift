import Foundation
import Observation

/// Lifetime per-agent activity counters, persisted across launches.
///
/// Deliberately schema-free: a flat `[agentKey: AgentStat]` bag whose
/// `counters` are an open `[String: Int]`. Adding a metric = write a new
/// counter name; adding an agent kind = nothing. Keys are opaque strings
/// (`AgentInvocationKey.statKey`) so the store never depends on agent
/// struct shape and survives as agentic features grow.
///
/// Stats are advisory and lossy-tolerant: a missing key reads as empty,
/// and an orphan key left behind by a deleted agent is harmless — the
/// overview only shows stats for agents a live descriptor resolves.
///
/// Persistence is a single JSON blob under `pupa.agentstats.v1`,
/// mirroring `MyAppStore` / `SettingsStore`.
@MainActor
@Observable
public final class AgentStatsStore {
    public static let storageKey = "pupa.agentstats.v1"

    /// Counter name: times this agent invoked another agent.
    public static let delegationsMade = "delegationsMade"
    /// Counter name: times this agent was invoked by another agent.
    public static let invocationsReceived = "invocationsReceived"

    public private(set) var stats: [String: AgentStat]

    /// Defaults domain reads and writes go to. Injectable so tests can use a
    /// throwaway suite instead of polluting `.standard`.
    private let defaults: UserDefaults

    /// `seed` skips the initial load; every `bump` still persists to `defaults`.
    public init(defaults: UserDefaults = .standard, seed: [String: AgentStat]? = nil) {
        self.defaults = defaults
        if let seed {
            stats = seed
        } else if let data = defaults.data(forKey: Self.storageKey),
                  let decoded = try? JSONDecoder().decode([String: AgentStat].self, from: data) {
            stats = decoded
        } else {
            stats = [:]
        }
    }

    /// Increment `counter` for `key` and stamp `lastActiveAt`. Persists.
    public func bump(_ key: String, _ counter: String, by amount: Int = 1) {
        var stat = stats[key] ?? AgentStat()
        stat.counters[counter, default: 0] += amount
        stat.lastActiveAt = Date()
        stats[key] = stat
        persist()
    }

    /// Stats for `key`, or an empty `AgentStat` when none recorded yet.
    public func stat(for key: String) -> AgentStat {
        stats[key] ?? AgentStat()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public static func clearStorage(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// One agent's counter bag plus the last time any counter moved.
public struct AgentStat: Codable, Hashable, Sendable {
    public var counters: [String: Int]
    public var lastActiveAt: Date?

    public init(counters: [String: Int] = [:], lastActiveAt: Date? = nil) {
        self.counters = counters
        self.lastActiveAt = lastActiveAt
    }

    /// Convenience reader: counter value, or 0 when absent.
    public func count(_ name: String) -> Int { counters[name] ?? 0 }
}
