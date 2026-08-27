import Foundation
import Testing
@testable import PupaApp

/// `enumerateAgents` runs from the Agents pane, which is keep-alive and so
/// mounts fresh on every MyApp switch. Each `MemoryStore` it builds is a full
/// recursive scan, so the count matters.
@MainActor
@Suite("Agent registry scanning")
struct AgentRegistryScanTests {

    init() { TestStorage.activate() }

    @Test("enumerating agents scans the app memory root once")
    func enumerateScansOnce() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "A", iconSystemName: "list.bullet", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: myApp.id))
        _ = try? memory.writeFile(
            path: "\(MemoryStore.pupaAgentsDir)/helper/AGENTS.md",
            content: "---\nname: Helper\ndescription: d\n---\n\nbody")

        DiskIO.reset()
        let descriptors = AgentRegistry.enumerateAgents(
            myApp: myApp, store: store, settings: SettingsStore(),
            catalog: ModelCatalogStore())

        // Main agent + the one subagent, from a single scan (was two).
        #expect(descriptors.count == 2)
        #expect(DiskIO.scans == 1, "scanned the memory root \(DiskIO.scans) times")
    }

    @Test("prompt links hide the myApp UUID folder")
    func promptLinkLabelDropsUUID() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "A", iconSystemName: "list.bullet", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: myApp.id))
        _ = try? memory.writeFile(
            path: "\(MemoryStore.pupaAgentsDir)/helper/AGENTS.md",
            content: "---\nname: Helper\ndescription: d\n---\n\nbody")

        let descriptors = AgentRegistry.enumerateAgents(
            myApp: myApp, store: store, settings: SettingsStore(),
            catalog: ModelCatalogStore())

        let uuid = myApp.id.uuidString.lowercased()
        for descriptor in descriptors {
            let prompt = descriptor.properties.first { $0.id == "prompt" }
            guard case .link(let label, let destination) = prompt?.value else {
                Issue.record("no prompt link on \(descriptor.name)")
                continue
            }
            #expect(!label.contains(uuid), "label leaks the myApp id: \(label)")
            #expect(label.hasPrefix("pupa/"))
            // The destination keeps the full, id-qualified path.
            guard case .myAppMemoryFile(_, let path) = destination else {
                Issue.record("prompt link is not a myApp memory file")
                continue
            }
            #expect(path.hasPrefix("\(uuid)/"))
        }
    }
}
