import Foundation
import Observation

/// Loads the automation rules that ride a `.pupa` bundle at
/// `pupa/automations.json`. Mirrors `SkillStore`: bound to one scope-rooted
/// `MemoryStore` (a MyApp's memory root), cache refreshed at `init` and via
/// `rescan()`. Missing / malformed config yields an empty rule set.
@MainActor
@Observable
public final class AutomationStore {
    /// Bundle-scoped rules file, alongside `pupa/skills/`.
    public static let path = "pupa/automations.json"

    private let memory: MemoryStore
    public private(set) var rules: [AutomationRule] = []

    public init(memory: MemoryStore) {
        self.memory = memory
        rescan()
    }

    /// Rebuild the cache from disk. Cheap (one small JSON file).
    public func rescan() {
        guard let read = try? memory.readFile(path: Self.path) else { rules = []; return }
        rules = AutomationRule.decodeSet(read.content)
    }
}
