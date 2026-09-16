import Foundation
import Testing
@testable import PupaApp

/// `enumerateAgents` runs from the Agents pane, which is keep-alive and so
/// mounts fresh on every MiniApp switch. Each `MemoryStore` it builds is a full
/// recursive scan, so the count matters.
@MainActor
@Suite("Agent registry scanning")
struct AgentRegistryScanTests {

    init() { TestStorage.activate() }

    @Test("legacy main agent id resolves to the current descriptor")
    func oldMainAgentId() {
        #expect(AgentRegistry.canonicalAgentId("myapp-main") == AgentRegistry.mainAgentId)
        #expect(AgentRegistry.canonicalAgentId("miniapp-main") == AgentRegistry.mainAgentId)
    }

    @Test("enumerating agents scans the app memory root once")
    func enumerateScansOnce() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "A", iconSystemName: "list.bullet", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: miniApp.id))
        _ = try? memory.writeFile(
            path: "\(MemoryStore.pupaAgentsDir)/helper/AGENTS.md",
            content: "---\nname: Helper\ndescription: d\n---\n\nbody")

        DiskIO.reset()
        let descriptors = AgentRegistry.enumerateAgents(
            miniApp: miniApp, store: store, settings: SettingsStore(),
            catalog: ModelCatalogStore())

        // Main agent + the one subagent, from a single scan (was two).
        #expect(descriptors.count == 2)
        #expect(DiskIO.scans == 1, "scanned the memory root \(DiskIO.scans) times")
    }
}
