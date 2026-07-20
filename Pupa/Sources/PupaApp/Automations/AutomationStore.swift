import Foundation
import Observation

/// Loads the automation rules that ride a `.pupa` bundle at
/// `pupa/automations.json`. Mirrors `SkillStore`: bound to one scope-rooted
/// `MemoryStore` (a MyApp's memory root), cache refreshed at `init` and via
/// `rescan()`. Missing / malformed config yields an empty rule set.
@MainActor
@Observable
public final class AutomationStore {
    private let memory: MemoryStore
    public private(set) var rules: [AutomationRule] = []

    public init(memory: MemoryStore) {
        self.memory = memory
        rescan()
    }

    /// Rebuild the cache from `pupa/automations.json`. Cheap (one small JSON
    /// file). Missing / malformed file → empty ruleset (never throws).
    public func rescan() {
        guard let read = try? memory.readFile(path: MemoryStore.pupaAutomationsPath) else {
            rules = []
            return
        }
        rules = AutomationConfig.parse(read.content)
    }

    /// Rules registered for one event type.
    public func rules(for event: CanvasEvent.EventType) -> [AutomationRule] {
        rules.filter { $0.event == event }
    }
}
