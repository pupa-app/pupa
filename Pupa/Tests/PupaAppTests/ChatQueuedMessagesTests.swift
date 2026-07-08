import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for queueing messages while a turn is in flight (pupa#119).
///
/// The mechanism under test is synchronous: `send` flips `isStreaming` on
/// before it kicks off the (async) network stream, so a follow-up `send` in
/// the same synchronous test body sees `isStreaming == true` and enqueues
/// instead of dropping. The doomed stream to the unreachable backend never
/// gets a suspension point to run, so `isStreaming` stays true for the
/// duration of each synchronous test — we tear it down with `cancel()`.
@MainActor
@Suite("ChatViewModel queued messages")
struct ChatQueuedMessagesTests {

    private func makeViewModel() -> ChatViewModel {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a], a.id))
        let memory = MemoryStore(
            rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pupa-tests-\(UUID().uuidString)")
        )
        let scope: ChatScope = .myApp(a.id)
        return ChatViewModel(
            store: store,
            memory: memory,
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!),
            registry: ToolRegistry(),
            scope: scope,
            threadId: store.currentThreadId(for: scope),
            toolGateState: ToolGateState()
        )
    }

    private func awaitBubbleAppear(_ vm: ChatViewModel) async {
        for _ in 0..<100 {
            if !vm.bubbles.isEmpty { return }
            await Task.yield()
        }
    }

    @Test("Sending while streaming queues the message instead of dropping it")
    func sendWhileStreaming_enqueues() {
        let vm = makeViewModel()

        vm.send("first message")
        #expect(vm.isStreaming)
        #expect(vm.queuedMessages.isEmpty)
        // The first message becomes a real user bubble immediately.
        #expect(vm.bubbles.filter { $0.role == .user }.count == 1)

        vm.send("second")
        vm.send("third")

        // Queued in FIFO order, and NOT added to the transcript yet.
        #expect(vm.queuedMessages.map(\.text) == ["second", "third"])
        #expect(vm.bubbles.filter { $0.role == .user }.count == 1)

        vm.cancel()
    }

    @Test("Empty / whitespace-only sends are never queued")
    func emptySendWhileStreaming_isNoOp() {
        let vm = makeViewModel()
        vm.send("first")
        #expect(vm.isStreaming)

        vm.send("   ")
        vm.send("")
        #expect(vm.queuedMessages.isEmpty)

        vm.cancel()
    }

    @Test("removeQueuedMessage cancels a pending message before it sends")
    func removeQueuedMessage_cancels() {
        let vm = makeViewModel()
        vm.send("first")
        vm.send("a")
        vm.send("b")
        vm.send("c")
        #expect(vm.queuedMessages.map(\.text) == ["a", "b", "c"])

        let bId = vm.queuedMessages[1].id
        vm.removeQueuedMessage(id: bId)
        #expect(vm.queuedMessages.map(\.text) == ["a", "c"])

        // Removing an unknown id is a harmless no-op.
        vm.removeQueuedMessage(id: "does-not-exist")
        #expect(vm.queuedMessages.map(\.text) == ["a", "c"])

        vm.cancel()
    }

    @Test("updateQueuedMessage edits text; trimmed-empty edit drops the item")
    func updateQueuedMessage_editsAndDrops() {
        let vm = makeViewModel()
        vm.send("first")
        vm.send("typo")
        let id = vm.queuedMessages[0].id

        vm.updateQueuedMessage(id: id, text: "  fixed  ")
        #expect(vm.queuedMessages[0].text == "fixed")

        vm.updateQueuedMessage(id: id, text: "   ")
        #expect(vm.queuedMessages.isEmpty, "emptying a text-only queued message removes it")

        vm.cancel()
    }

    @Test("cancel() (Stop) discards queued messages and stops streaming")
    func cancelClearsQueue() {
        let vm = makeViewModel()
        vm.send("first")
        vm.send("queued-1")
        vm.send("queued-2")
        #expect(vm.queuedMessages.count == 2)

        vm.cancel()
        #expect(vm.queuedMessages.isEmpty)
        #expect(vm.isStreaming == false)
    }

    @Test("newThread() clears the queue")
    func newThreadClearsQueue() {
        let vm = makeViewModel()
        vm.send("first")
        vm.send("queued")
        #expect(vm.queuedMessages.count == 1)

        vm.newThread()
        #expect(vm.queuedMessages.isEmpty)
    }

    @Test("Sending while parked on a human-in-the-loop interrupt is dropped, not queued")
    func sendWhileAwaitingHumanInput_dropsNotQueues() async {
        let vm = makeViewModel()

        async let answers = vm.askQuestions([
            HumanQuestionRow(question: "Which one?", options: []),
        ])
        await awaitBubbleAppear(vm)
        #expect(vm.isAwaitingHumanInput)

        vm.send("a stray message")
        #expect(vm.queuedMessages.isEmpty, "interrupts gate the composer — send is dropped, not queued")

        vm.newThread()
        _ = await answers
    }

    @Test("The whole queue coalesces into one message: texts joined FIFO, every image kept in order")
    func coalesceQueue_mergesIntoSingleMessage() {
        // Empty queue → nothing to drain.
        #expect(ChatViewModel.coalesceQueue([]) == nil)

        let imgA = PickedImage(data: Data([0xA, 0xB]), mimeType: "image/png")
        let imgB = PickedImage(data: Data([0xC]), mimeType: "image/png")
        let imgC = PickedImage(data: Data([0xD, 0xE]), mimeType: "image/jpeg")
        let queue = [
            QueuedMessage(text: "one"),
            QueuedMessage(text: "two", images: [imgA]),
            QueuedMessage(text: "", images: [imgB, imgC]),  // image-only item
            QueuedMessage(text: "three"),
        ]
        let merged = ChatViewModel.coalesceQueue(queue)
        // FIFO order, blank-line separated, empty text components skipped.
        #expect(merged?.text == "one\n\ntwo\n\nthree")
        // Every attached image is kept, in queue order (regression: previously
        // only the first survived).
        #expect(merged?.images == [imgA, imgB, imgC])
    }

    @Test("coalesceQueue truncates merged images to the per-message cap")
    func coalesceQueue_capsImages() {
        let over = ChatViewModel.maxImagesPerMessage + 5
        let queue = (0..<over).map {
            QueuedMessage(text: "", images: [PickedImage(data: Data([UInt8($0 % 256)]), mimeType: "image/png")])
        }
        let merged = ChatViewModel.coalesceQueue(queue)
        #expect(merged?.images.count == ChatViewModel.maxImagesPerMessage)
    }

    @Test("A queued message carrying images round-trips its PickedImages")
    func queuedMessage_reconstitutesImages() {
        let a = PickedImage(data: Data([0x1, 0x2]), mimeType: "image/png")
        let b = PickedImage(data: Data([0x3]), mimeType: "image/jpeg")
        let withImages = QueuedMessage(text: "look", images: [a, b])
        #expect(withImages.pickedImages == [a, b])

        let noImage = QueuedMessage(text: "plain")
        #expect(noImage.pickedImages.isEmpty)
    }
}
