import Foundation
import Observation

/// Discovers and caches a scope's automation rules from
/// `pupa/automations.json`. Mirrors `SkillStore`: bound to one scope-rooted
/// `MemoryStore`, refreshed at `init` and via `rescan()` when memory mutates.
@MainActor
@Observable
public final class AutomationStore {
    private let memory: MemoryStore
    public private(set) var rules: [AutomationRule] = []

    public init(memory: MemoryStore) {
        self.memory = memory
        rescan()
    }

    /// Rebuild the cache from `pupa/automations.json`. Idempotent and cheap.
    /// Missing or malformed file → empty ruleset (never throws).
    public func rescan() {
        guard let read = try? memory.readFile(path: MemoryStore.pupaAutomationsPath) else {
            rules = []
            return
        }
        rules = AutomationConfig.parse(read.content)
    }

    /// Rules registered for one event type.
    public func rules(for event: CanvasEventType) -> [AutomationRule] {
        rules.filter { $0.event == event }
    }
}
