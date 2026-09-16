import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the orchestrator tool surface installed on the memory-mode
/// session in [#18](https://github.com/*/issues/18):
/// `listMiniApps`, `createMiniApp`, and `invokeMiniAppAgent`. The first two are
/// pure `MiniAppStore` shims and fully unit-testable here. `invokeMiniAppAgent`
/// hits a backend round-trip via `runOneShot`, so we only test argument
/// validation + the `parallelSafe` opt-in (the actual end-to-end sub-run is
/// exercised in the AGUIKit `parallelSafeTools_*` regression test and
/// manually per the issue's verification plan).
@MainActor
@Suite("Orchestrator tools")
struct OrchestratorToolsTests {

    private func makeStore() -> (store: MiniAppStore, a: UUID, b: UUID) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniAppA = MiniApp(name: "Garden", iconSystemName: "leaf", typeId: MiniAppType.tracker.id)
        let miniAppB = MiniApp(name: "Books", iconSystemName: "book", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniAppA, miniAppB], miniAppA.id))
        return (store, miniAppA.id, miniAppB.id)
    }

    /// `runOneShot` stub that records its invocations and returns a canned
    /// reply per `miniAppId`. Lets us exercise `invokeMiniAppAgent`'s arg
    /// validation and result shape without standing up an AGUIKit session.
    private final class RunOneShotRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(miniAppId: UUID, prompt: String)] = []
        var calls: [(miniAppId: UUID, prompt: String)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func record(miniAppId: UUID, prompt: String) {
            lock.lock(); defer { lock.unlock() }
            _calls.append((miniAppId, prompt))
        }
    }

    @Test("listMiniApps returns every miniApp in sidebar order with id/typeId/name/iconSystemName")
    func listSpaces_returnsAllSpaces() async throws {
        let (store, idA, idB) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        guard let tool = registry.resolve("listMiniApps") else {
            Issue.record("listMiniApps not registered")
            return
        }
        let result = try await tool.handler(.object([:]))
        let miniApps = try #require(result["miniApps"]?.arrayValue)
        #expect(miniApps.count == 2)
        #expect(miniApps[0]["id"]?.stringValue == idA.uuidString)
        #expect(miniApps[0]["name"]?.stringValue == "Garden")
        #expect(miniApps[0]["typeId"]?.stringValue == "tracker")
        #expect(miniApps[0]["iconSystemName"]?.stringValue == "leaf")
        #expect(miniApps[1]["id"]?.stringValue == idB.uuidString)
        #expect(miniApps[1]["name"]?.stringValue == "Books")
    }

    @Test("Old orchestrator tools keep their old argument and result fields")
    func legacyToolAliases() async throws {
        let (store, id, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })
        let list = try #require(registry.resolve("listMyApps"))
        let listed = try await list.handler(.object([:]))
        #expect(listed["myApps"]?.arrayValue?.count == 2)
        let rename = try #require(registry.resolve("renameMyApp"))
        let result = try await rename.handler(.object([
            "myAppId": .string(id.uuidString), "name": .string("New Garden")
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(store.miniApp(withId: id)?.name == "New Garden")
    }

    @Test("Disabling an old tool name also disables its MiniApp name")
    func legacyDisabledToolNames() {
        TestStorage.activate()
        SettingsStore.clearStorage()
        let settings = SettingsStore(credentials: InMemoryCredentialStore())
        settings.setOrchestratorDisabledTools(["renameMyApp"])
        #expect(settings.orchestratorDisabledTools.contains("renameMiniApp"))
        let reader = SettingsStore(credentials: InMemoryCredentialStore())
        #expect(reader.orchestratorDisabledTools.contains("renameMiniApp"))
    }

    @Test("createMiniApp appends a new miniApp via MiniAppStore.addMiniApp and returns its id")
    func createSpace_appendsToStore() async throws {
        let (store, _, _) = makeStore()
        let before = store.miniApps.count
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        guard let tool = registry.resolve("createMiniApp") else {
            Issue.record("createMiniApp not registered")
            return
        }
        let result = try await tool.handler(.object([
            "typeId": .string("tracker"),
            "name": .string("Plants"),
            "iconSystemName": .string("leaf.circle"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        let newIdString = try #require(result["id"]?.stringValue)
        let newId = try #require(UUID(uuidString: newIdString))
        #expect(store.miniApps.count == before + 1)
        #expect(store.miniApps.contains(where: { $0.id == newId && $0.name == "Plants" }))
        #expect(store.miniApps.last?.iconSystemName == "leaf.circle")
    }

    @Test("createMiniApp rejects unknown typeId and does NOT mutate the store")
    func createSpace_rejectsUnknownType() async throws {
        let (store, _, _) = makeStore()
        let before = store.miniApps.count
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("createMiniApp"))
        let result = try await tool.handler(.object([
            "typeId": .string("not-a-real-type"),
            "name": .string("Whatever"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.miniApps.count == before)
    }

    @Test("renameMiniApp updates store.miniApps[i].name and echoes previousName")
    func renameMiniApp_appliesToStore() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMiniApp"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "name": .string("Plants"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["id"]?.stringValue == idA.uuidString)
        #expect(result["name"]?.stringValue == "Plants")
        #expect(result["previousName"]?.stringValue == "Garden")
        #expect(store.miniApps.first(where: { $0.id == idA })?.name == "Plants")
    }

    @Test("renameMiniApp rejects an unknown miniAppId without mutating the store")
    func renameMiniApp_rejectsUnknownId() async throws {
        let (store, _, _) = makeStore()
        let before = store.miniApps.map(\.name)
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMiniApp"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(UUID().uuidString),
            "name": .string("Whatever"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.miniApps.map(\.name) == before)
    }

    @Test("renameMiniApp rejects a malformed miniAppId (not a UUID)")
    func renameMiniApp_rejectsMalformedId() async throws {
        let (store, _, _) = makeStore()
        let before = store.miniApps.map(\.name)
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMiniApp"))
        let result = try await tool.handler(.object([
            "miniAppId": .string("not-a-uuid"),
            "name": .string("Plants"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.miniApps.map(\.name) == before)
    }

    @Test("renameMiniApp rejects an empty / whitespace-only name without mutating the store")
    func renameMiniApp_rejectsEmptyName() async throws {
        let (store, idA, _) = makeStore()
        let before = store.miniApps.map(\.name)
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMiniApp"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "name": .string("   "),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.miniApps.map(\.name) == before)
    }

    @Test("invokeMiniAppAgent forwards (miniAppId, prompt) to runOneShot and returns the text")
    func invokeSpaceAgent_forwardsToRunOneShot() async throws {
        let (store, idA, _) = makeStore()
        let recorder = RunOneShotRecorder()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(
            on: registry,
            store: store,
            runOneShot: { miniAppId, prompt in
                recorder.record(miniAppId: miniAppId, prompt: prompt)
                return "sub-agent reply for \(prompt)"
            }
        )

        let tool = try #require(registry.resolve("invokeMiniAppAgent"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "prompt": .string("suggest 3 plants"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["miniAppId"]?.stringValue == idA.uuidString)
        #expect(result["text"]?.stringValue == "sub-agent reply for suggest 3 plants")
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].miniAppId == idA)
        #expect(recorder.calls[0].prompt == "suggest 3 plants")
    }

    @Test("invokeMiniAppAgent rejects an unknown miniAppId without invoking runOneShot")
    func invokeSpaceAgent_rejectsUnknownSpace() async throws {
        let (store, _, _) = makeStore()
        let recorder = RunOneShotRecorder()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(
            on: registry,
            store: store,
            runOneShot: { miniAppId, prompt in
                recorder.record(miniAppId: miniAppId, prompt: prompt)
                return ""
            }
        )

        let tool = try #require(registry.resolve("invokeMiniAppAgent"))
        let fake = UUID()
        let result = try await tool.handler(.object([
            "miniAppId": .string(fake.uuidString),
            "prompt": .string("hi"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(recorder.calls.isEmpty, "runOneShot must not be invoked for an unknown miniAppId")
    }

    @Test("invokeMiniAppAgent rejects a malformed miniAppId (not a UUID)")
    func invokeSpaceAgent_rejectsMalformedSpaceId() async throws {
        let (store, _, _) = makeStore()
        let recorder = RunOneShotRecorder()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(
            on: registry,
            store: store,
            runOneShot: { miniAppId, prompt in
                recorder.record(miniAppId: miniAppId, prompt: prompt)
                return ""
            }
        )

        let tool = try #require(registry.resolve("invokeMiniAppAgent"))
        let result = try await tool.handler(.object([
            "miniAppId": .string("not-a-uuid"),
            "prompt": .string("hi"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(recorder.calls.isEmpty)
    }

    @Test("invokeMiniAppAgent is marked parallelSafe; the other two orchestrator tools are not")
    func invokeSpaceAgent_isParallelSafe() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        #expect(registry.resolve("invokeMiniAppAgent")?.parallelSafe == true)
        #expect(registry.resolve("listMiniApps")?.parallelSafe == false)
        #expect(registry.resolve("createMiniApp")?.parallelSafe == false)
        #expect(registry.resolve("renameMiniApp")?.parallelSafe == false)
    }

    @Test("Orchestrator tool names match MiniAppType.orchestratorToolNames exactly")
    func orchestratorToolNames_matchRegistration() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let registered = Set(registry.descriptors.map(\.name))
        #expect(registered == MiniAppType.orchestratorToolNames,
                "Registered tools \(registered) drift from MiniAppType.orchestratorToolNames \(MiniAppType.orchestratorToolNames)")
    }

    // MARK: - setMiniAppIcon

    @Test("setMiniAppIcon updates the store icon and echoes previousIconSystemName")
    func setMiniAppIcon_appliesToStore() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMiniAppIcon"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "iconSystemName": .string("carrot"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["iconSystemName"]?.stringValue == "carrot")
        #expect(result["previousIconSystemName"]?.stringValue == "leaf")
        #expect(store.miniApps.first(where: { $0.id == idA })?.iconSystemName == "carrot")
    }

    @Test("setMiniAppIcon rejects an empty icon and does NOT mutate the store")
    func setMiniAppIcon_rejectsEmpty() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMiniAppIcon"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "iconSystemName": .string("   "),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.miniApps.first(where: { $0.id == idA })?.iconSystemName == "leaf")
    }

    @Test("setMiniAppIcon rejects an unknown miniAppId")
    func setMiniAppIcon_rejectsUnknownId() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMiniAppIcon"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(UUID().uuidString),
            "iconSystemName": .string("star"),
        ]))
        #expect(result["ok"]?.boolValue == false)
    }

    // MARK: - setMiniAppColor

    @Test("setMiniAppColor updates the store colorIndex and echoes previousColorIndex")
    func setMiniAppColor_appliesToStore() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let previous = store.colorIndex(for: idA)
        let tool = try #require(registry.resolve("setMiniAppColor"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "colorIndex": .int(5),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["colorIndex"]?.intValue == 5)
        #expect(result["previousColorIndex"]?.intValue == previous)
        #expect(store.colorIndex(for: idA) == 5)
    }

    @Test("setMiniAppColor rejects a negative colorIndex and does NOT mutate the store")
    func setMiniAppColor_rejectsNegative() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let before = store.colorIndex(for: idA)
        let tool = try #require(registry.resolve("setMiniAppColor"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(idA.uuidString),
            "colorIndex": .int(-1),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.colorIndex(for: idA) == before)
    }

    @Test("setMiniAppColor rejects an unknown miniAppId")
    func setMiniAppColor_rejectsUnknownId() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMiniAppColor"))
        let result = try await tool.handler(.object([
            "miniAppId": .string(UUID().uuidString),
            "colorIndex": .int(2),
        ]))
        #expect(result["ok"]?.boolValue == false)
    }
}
