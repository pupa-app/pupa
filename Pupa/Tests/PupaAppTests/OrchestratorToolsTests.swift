import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the orchestrator tool surface installed on the memory-mode
/// session in [#18](https://github.com/*/issues/18):
/// `listMyApps`, `createMyApp`, and `invokeMyAppAgent`. The first two are
/// pure `MyAppStore` shims and fully unit-testable here. `invokeMyAppAgent`
/// hits a backend round-trip via `runOneShot`, so we only test argument
/// validation + the `parallelSafe` opt-in (the actual end-to-end sub-run is
/// exercised in the AGUIKit `parallelSafeTools_*` regression test and
/// manually per the issue's verification plan).
@MainActor
@Suite("Orchestrator tools")
struct OrchestratorToolsTests {

    private func makeStore() -> (store: MyAppStore, a: UUID, b: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myAppA = MyApp(name: "Garden", iconSystemName: "leaf", typeId: MyAppType.tracker.id)
        let myAppB = MyApp(name: "Books", iconSystemName: "book", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myAppA, myAppB], myAppA.id))
        return (store, myAppA.id, myAppB.id)
    }

    /// `runOneShot` stub that records its invocations and returns a canned
    /// reply per `myAppId`. Lets us exercise `invokeMyAppAgent`'s arg
    /// validation and result shape without standing up an AGUIKit session.
    private final class RunOneShotRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(myAppId: UUID, prompt: String)] = []
        var calls: [(myAppId: UUID, prompt: String)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func record(myAppId: UUID, prompt: String) {
            lock.lock(); defer { lock.unlock() }
            _calls.append((myAppId, prompt))
        }
    }

    @Test("listMyApps returns every myApp in sidebar order with id/typeId/name/iconSystemName")
    func listSpaces_returnsAllSpaces() async throws {
        let (store, idA, idB) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        guard let tool = registry.resolve("listMyApps") else {
            Issue.record("listMyApps not registered")
            return
        }
        let result = try await tool.handler(.object([:]))
        let myApps = try #require(result["myApps"]?.arrayValue)
        #expect(myApps.count == 2)
        #expect(myApps[0]["id"]?.stringValue == idA.uuidString)
        #expect(myApps[0]["name"]?.stringValue == "Garden")
        #expect(myApps[0]["typeId"]?.stringValue == "tracker")
        #expect(myApps[0]["iconSystemName"]?.stringValue == "leaf")
        #expect(myApps[1]["id"]?.stringValue == idB.uuidString)
        #expect(myApps[1]["name"]?.stringValue == "Books")
    }

    @Test("createMyApp appends a new myApp via MyAppStore.addMyApp and returns its id")
    func createSpace_appendsToStore() async throws {
        let (store, _, _) = makeStore()
        let before = store.myApps.count
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        guard let tool = registry.resolve("createMyApp") else {
            Issue.record("createMyApp not registered")
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
        #expect(store.myApps.count == before + 1)
        #expect(store.myApps.contains(where: { $0.id == newId && $0.name == "Plants" }))
        #expect(store.myApps.last?.iconSystemName == "leaf.circle")
    }

    @Test("createMyApp rejects unknown typeId and does NOT mutate the store")
    func createSpace_rejectsUnknownType() async throws {
        let (store, _, _) = makeStore()
        let before = store.myApps.count
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("createMyApp"))
        let result = try await tool.handler(.object([
            "typeId": .string("not-a-real-type"),
            "name": .string("Whatever"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.myApps.count == before)
    }

    @Test("renameMyApp updates store.myApps[i].name and echoes previousName")
    func renameMyApp_appliesToStore() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMyApp"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "name": .string("Plants"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["id"]?.stringValue == idA.uuidString)
        #expect(result["name"]?.stringValue == "Plants")
        #expect(result["previousName"]?.stringValue == "Garden")
        #expect(store.myApps.first(where: { $0.id == idA })?.name == "Plants")
    }

    @Test("renameMyApp rejects an unknown myAppId without mutating the store")
    func renameMyApp_rejectsUnknownId() async throws {
        let (store, _, _) = makeStore()
        let before = store.myApps.map(\.name)
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMyApp"))
        let result = try await tool.handler(.object([
            "myAppId": .string(UUID().uuidString),
            "name": .string("Whatever"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.myApps.map(\.name) == before)
    }

    @Test("renameMyApp rejects a malformed myAppId (not a UUID)")
    func renameMyApp_rejectsMalformedId() async throws {
        let (store, _, _) = makeStore()
        let before = store.myApps.map(\.name)
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMyApp"))
        let result = try await tool.handler(.object([
            "myAppId": .string("not-a-uuid"),
            "name": .string("Plants"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.myApps.map(\.name) == before)
    }

    @Test("renameMyApp rejects an empty / whitespace-only name without mutating the store")
    func renameMyApp_rejectsEmptyName() async throws {
        let (store, idA, _) = makeStore()
        let before = store.myApps.map(\.name)
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("renameMyApp"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "name": .string("   "),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.myApps.map(\.name) == before)
    }

    @Test("invokeMyAppAgent forwards (myAppId, prompt) to runOneShot and returns the text")
    func invokeSpaceAgent_forwardsToRunOneShot() async throws {
        let (store, idA, _) = makeStore()
        let recorder = RunOneShotRecorder()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(
            on: registry,
            store: store,
            runOneShot: { myAppId, prompt in
                recorder.record(myAppId: myAppId, prompt: prompt)
                return "sub-agent reply for \(prompt)"
            }
        )

        let tool = try #require(registry.resolve("invokeMyAppAgent"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "prompt": .string("suggest 3 plants"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["myAppId"]?.stringValue == idA.uuidString)
        #expect(result["text"]?.stringValue == "sub-agent reply for suggest 3 plants")
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].myAppId == idA)
        #expect(recorder.calls[0].prompt == "suggest 3 plants")
    }

    @Test("invokeMyAppAgent rejects an unknown myAppId without invoking runOneShot")
    func invokeSpaceAgent_rejectsUnknownSpace() async throws {
        let (store, _, _) = makeStore()
        let recorder = RunOneShotRecorder()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(
            on: registry,
            store: store,
            runOneShot: { myAppId, prompt in
                recorder.record(myAppId: myAppId, prompt: prompt)
                return ""
            }
        )

        let tool = try #require(registry.resolve("invokeMyAppAgent"))
        let fake = UUID()
        let result = try await tool.handler(.object([
            "myAppId": .string(fake.uuidString),
            "prompt": .string("hi"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(recorder.calls.isEmpty, "runOneShot must not be invoked for an unknown myAppId")
    }

    @Test("invokeMyAppAgent rejects a malformed myAppId (not a UUID)")
    func invokeSpaceAgent_rejectsMalformedSpaceId() async throws {
        let (store, _, _) = makeStore()
        let recorder = RunOneShotRecorder()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(
            on: registry,
            store: store,
            runOneShot: { myAppId, prompt in
                recorder.record(myAppId: myAppId, prompt: prompt)
                return ""
            }
        )

        let tool = try #require(registry.resolve("invokeMyAppAgent"))
        let result = try await tool.handler(.object([
            "myAppId": .string("not-a-uuid"),
            "prompt": .string("hi"),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(recorder.calls.isEmpty)
    }

    @Test("invokeMyAppAgent is marked parallelSafe; the other two orchestrator tools are not")
    func invokeSpaceAgent_isParallelSafe() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        #expect(registry.resolve("invokeMyAppAgent")?.parallelSafe == true)
        #expect(registry.resolve("listMyApps")?.parallelSafe == false)
        #expect(registry.resolve("createMyApp")?.parallelSafe == false)
        #expect(registry.resolve("renameMyApp")?.parallelSafe == false)
    }

    @Test("Orchestrator tool names match MyAppType.orchestratorToolNames exactly")
    func orchestratorToolNames_matchRegistration() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let registered = Set(registry.descriptors.map(\.name))
        #expect(registered == MyAppType.orchestratorToolNames,
                "Registered tools \(registered) drift from MyAppType.orchestratorToolNames \(MyAppType.orchestratorToolNames)")
    }

    // MARK: - setMyAppIcon

    @Test("setMyAppIcon updates the store icon and echoes previousIconSystemName")
    func setMyAppIcon_appliesToStore() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMyAppIcon"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "iconSystemName": .string("carrot"),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["iconSystemName"]?.stringValue == "carrot")
        #expect(result["previousIconSystemName"]?.stringValue == "leaf")
        #expect(store.myApps.first(where: { $0.id == idA })?.iconSystemName == "carrot")
    }

    @Test("setMyAppIcon rejects an empty icon and does NOT mutate the store")
    func setMyAppIcon_rejectsEmpty() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMyAppIcon"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "iconSystemName": .string("   "),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.myApps.first(where: { $0.id == idA })?.iconSystemName == "leaf")
    }

    @Test("setMyAppIcon rejects an unknown myAppId")
    func setMyAppIcon_rejectsUnknownId() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMyAppIcon"))
        let result = try await tool.handler(.object([
            "myAppId": .string(UUID().uuidString),
            "iconSystemName": .string("star"),
        ]))
        #expect(result["ok"]?.boolValue == false)
    }

    // MARK: - setMyAppColor

    @Test("setMyAppColor updates the store colorIndex and echoes previousColorIndex")
    func setMyAppColor_appliesToStore() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let previous = store.colorIndex(for: idA)
        let tool = try #require(registry.resolve("setMyAppColor"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "colorIndex": .int(5),
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["colorIndex"]?.intValue == 5)
        #expect(result["previousColorIndex"]?.intValue == previous)
        #expect(store.colorIndex(for: idA) == 5)
    }

    @Test("setMyAppColor rejects a negative colorIndex and does NOT mutate the store")
    func setMyAppColor_rejectsNegative() async throws {
        let (store, idA, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let before = store.colorIndex(for: idA)
        let tool = try #require(registry.resolve("setMyAppColor"))
        let result = try await tool.handler(.object([
            "myAppId": .string(idA.uuidString),
            "colorIndex": .int(-1),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(store.colorIndex(for: idA) == before)
    }

    @Test("setMyAppColor rejects an unknown myAppId")
    func setMyAppColor_rejectsUnknownId() async throws {
        let (store, _, _) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerOrchestratorTools(on: registry, store: store, runOneShot: { _, _ in "" })

        let tool = try #require(registry.resolve("setMyAppColor"))
        let result = try await tool.handler(.object([
            "myAppId": .string(UUID().uuidString),
            "colorIndex": .int(2),
        ]))
        #expect(result["ok"]?.boolValue == false)
    }
}
