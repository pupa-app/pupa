import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// The turn-state probe and the `.reattaching` banner it reports on.
///
/// The probe is the only channel a simulator UI test has for recovery state —
/// the runner and the app don't share a sandbox — so its payload is a contract,
/// not a debug aid. These run at the view-model layer, where the state machine
/// is, rather than in the UI suite that can only read the result.
@MainActor
@Suite("Turn state probe")
struct TurnStateProbeTests {

    init() { TestStorage.activate() }

    private func makeVM() -> ChatViewModel {
        MyAppTypeRegistry.shared.registerBuiltins()
        let app = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([app], app.id))
        let memory = MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)"))
        return ChatViewModel(
            store: store, memory: memory,
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!),
            registry: ToolRegistry(), scope: .myApp(app.id),
            threadId: store.currentThreadId(for: .myApp(app.id)),
            urlSession: .shared, toolGateState: ToolGateState())
    }

    private func field(_ json: String, _ key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let value = obj[key] else { return nil }
        if value is NSNull { return "null" }
        return String(describing: value)
    }

    /// The whole payload has to survive `JSONSerialization` — it is hand-built,
    /// so a stray unescaped value would break every test that reads it.
    @Test("the payload is valid JSON carrying every recovery field")
    func probePayload_isWellFormed() {
        let vm = makeVM()
        let json = vm.probeStateJSON
        #expect(field(json, "ci") == "null")
        #expect(field(json, "s") == "0")
        #expect(field(json, "pd") == "null")
        #expect(field(json, "nr") == "null")
        #expect(field(json, "th") == vm.threadId)

        vm.apply(.frontendDispatchParked(afterSeq: 7))
        vm.apply(.cursorAdvanced(9))
        #expect(field(vm.probeStateJSON, "pd") == "7")
        #expect(field(vm.probeStateJSON, "seq") == "9")
    }

    /// `ev` is the narrative — what a UI test reads to tell "parked twice" from
    /// "parked once", which no single boolean can express.
    @Test("the event ring records kinds in order and stays bounded")
    func probeRing_isOrderedAndBounded() {
        let vm = makeVM()
        vm.recordProbe(.cursorAdvanced(1))
        vm.recordProbe(.frontendDispatchParked(afterSeq: 2))
        vm.recordProbe(.frontendDispatchResolved)
        #expect(field(vm.probeStateJSON, "ev") == "cur,fdp,fdr")

        let before = vm.probeGeneration
        for i in 0..<30 { vm.recordProbe(.cursorAdvanced(i)) }
        let ring = field(vm.probeStateJSON, "ev")?.split(separator: ",") ?? []
        #expect(ring.count == 12, "the ring is capped so the payload stays under a kilobyte")
        #expect(vm.probeGeneration == before + 30, "every change moves the generation")
    }

    /// Symptom 1's "sticks on Reconnecting…": the retry ladder now says so
    /// during the backoff, instead of leaving the user on "Working…" for the
    /// whole budget and then handing them a banner with no account of the gap.
    @Test("a retry raises the banner, and the frame that follows clears it")
    func reattaching_raisesThenClearsTheBanner() {
        let vm = makeVM()
        #expect(vm.connectionIssue == nil)

        vm.apply(.reattaching(attempt: 1, of: 4))
        #expect(vm.connectionIssue == .reconnecting)
        #expect(field(vm.probeStateJSON, "ra") == "1")

        vm.apply(.reattaching(attempt: 2, of: 4))
        #expect(field(vm.probeStateJSON, "ra") == "2")

        // The retry connected.
        vm.apply(.assistantMessageStart(messageId: "m1"))
        #expect(vm.connectionIssue == nil, "a latched banner reads as a turn stuck forever")
        #expect(field(vm.probeStateJSON, "ra") == "0")
    }

    /// The narrowing that keeps `continueDroppedTurn` reachable: its gate is
    /// `connectionIssue != nil`, so clearing a banner this stream did not raise
    /// would silently disarm the Continue button.
    @Test("a banner from a dead stream survives later events")
    func banner_fromEarlierStream_isNotCleared() {
        let vm = makeVM()
        vm.apply(.error(message: "boom", code: nil))
        #expect(vm.connectionIssue != nil, "setup: a failed turn left a banner up")

        vm.apply(.frontendDispatchParked(afterSeq: 4))
        #expect(vm.connectionIssue != nil, "no retry raised this one — it is not ours to clear")
    }

    /// `nr` is how a test tells the notice ending from the throw ending — the
    /// two disjoint ways a dropped turn finishes.
    @Test("a turn that stops short reports why")
    func noticeReason_isReported() {
        let vm = makeVM()
        vm.apply(.completed(.silent(.emptyTurn)))
        #expect(field(vm.probeStateJSON, "nr") == "emptyTurn")
        #expect(field(vm.probeStateJSON, "ci") == "null", "the notice ending raises no banner")
    }
}
