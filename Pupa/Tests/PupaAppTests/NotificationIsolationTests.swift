import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins cross-miniApp isolation on `sendNotification`. A notification's target is
/// bound to the scope of the agent that scheduled it — never to a value the
/// model supplies — so one miniApp can't open or message another (pupa-backend#72).
///
/// Two layers are covered:
///  - **Parse** (`NotificationRequest.init(fromToolArgs:)`): a model-supplied
///    `target.miniAppId` is ignored; only `componentId` survives.
///  - **Scope binding** (`AppTools.scopeNotificationRequest`): the owning miniApp
///    is injected, foreground taps included; the orchestrator is left unchanged
///    (routed to its own chat at delivery time).
@Suite("Notification cross-miniApp isolation")
@MainActor
struct NotificationIsolationTests {

    private func request(
        target: NotificationRequest.Target? = nil,
        tapAction: NotificationRequest.TapAction = .foreground
    ) -> NotificationRequest {
        NotificationRequest(title: "hi", body: "there", trigger: .now, target: target, tapAction: tapAction)
    }

    // MARK: - Parse: a model can't name a target miniApp

    @Test("a model-supplied target.miniAppId is ignored at parse")
    func parseIgnoresModelMiniAppId() throws {
        let args: AnyJSON = .object([
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object([
                "miniAppId": .string(UUID().uuidString),   // a sibling — must be dropped
                "componentId": .string("tracker-1"),
            ]),
        ])
        let parsed = try NotificationRequest(fromToolArgs: args)
        #expect(parsed.target?.miniAppId == nil)
        #expect(parsed.target?.componentId == "tracker-1")
    }

    // MARK: - Scope binding: the owning miniApp is injected

    @Test("a miniApp notification is always bound to its own id — foreground taps too")
    func bindsForegroundToOwner() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(request(tapAction: .foreground), ownerMiniAppId: owner)
        #expect(scoped.target?.miniAppId == owner)
    }

    @Test("a runAgent tap is bound to the owner, never the active scope")
    func bindsRunAgentToOwner() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(
            request(tapAction: .runAgent(prompt: "do x")), ownerMiniAppId: owner
        )
        #expect(scoped.target?.miniAppId == owner)
        #expect(scoped.tapAction == .runAgent(prompt: "do x"))
    }

    @Test("a populateChat tap is bound to the owner")
    func bindsPopulateChatToOwner() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(
            request(tapAction: .populateChat(prompt: "draft this")), ownerMiniAppId: owner
        )
        #expect(scoped.target?.miniAppId == owner)
    }

    @Test("a chosen componentId is preserved while the miniApp id is injected")
    func preservesComponentIdWhileBinding() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(
            request(target: .init(miniAppId: nil, componentId: "tracker-1"), tapAction: .runAgent(prompt: "x")),
            ownerMiniAppId: owner
        )
        #expect(scoped.target?.miniAppId == owner)
        #expect(scoped.target?.componentId == "tracker-1")
    }

    // MARK: - Orchestrator scope (nil owner) is left for delivery-time routing

    @Test("orchestrator scope (nil owner) is returned unchanged")
    func orchestratorUnchanged() {
        let req = request(tapAction: .runAgent(prompt: "x"))
        let scoped = AppTools.scopeNotificationRequest(req, ownerMiniAppId: nil)
        #expect(scoped == req)
        #expect(scoped.target?.miniAppId == nil)
    }

    // MARK: - Origin: who created it, as opposed to where it links

    @Test("a miniApp session credits its own miniApp; the orchestrator credits itself")
    func originFollowsScope() {
        let miniAppId = UUID()
        #expect(AppTools.notificationOrigin(ownerMiniAppId: miniAppId) == .miniApp(miniAppId))
        #expect(AppTools.notificationOrigin(ownerMiniAppId: nil) == .orchestrator)
    }

    @Test("an edit keeps the deep-link target and tap action it was scheduled with")
    func editPreservesRouting() {
        let miniAppId = UUID()
        let original = NotificationRequest(
            title: "Stand up", body: "time to move",
            trigger: .daily(hour: 9, minute: 0),
            target: .init(miniAppId: miniAppId, componentId: "tracker-1"),
            tapAction: .runAgent(prompt: "log it")
        )

        let edited = NotificationRequest.edited(
            title: "Stretch", body: "time to move",
            trigger: .daily(hour: 10, minute: 30),
            preserving: original
        )

        // Retiming must not sever the route back into the owning miniApp.
        #expect(edited.target?.miniAppId == miniAppId)
        #expect(edited.target?.componentId == "tracker-1")
        #expect(edited.tapAction == .runAgent(prompt: "log it"))
        #expect(edited.title == "Stretch")
        #expect(edited.trigger == .daily(hour: 10, minute: 30))
    }

    @Test("composing a new notification has no target and just foregrounds")
    func freshComposeHasNoRouting() {
        let fresh = NotificationRequest.edited(
            title: "Tea", body: "kettle", trigger: .now, preserving: nil
        )

        #expect(fresh.target == nil)
        #expect(fresh.tapAction == .foreground)
    }

    // MARK: - Handler wiring: no reject path remains; the request reaches scheduling

    @Test("the sendNotification handler binds and schedules (no target rejection)")
    func handlerBindsAndSchedules() async throws {
        let registry = ToolRegistry()
        AppTools.registerNotificationTools(
            on: registry,
            coordinator: .shared,
            toolGateState: ToolGateState(),
            ownerMiniAppId: UUID()
        )
        let tool = registry.resolve("sendNotification")!
        let args: AnyJSON = .object([
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object(["miniAppId": .string(UUID().uuidString)]),  // ignored, not rejected
        ])
        let result = try await tool.handler(args)
        // The old reject path is gone; on the test host (no bundle id) scheduling
        // reports `notifications-unsupported-host` — proof the request passed the
        // scope binding and reached `coordinator.schedule`.
        #expect(result["error"]?.stringValue != "notification-target-not-permitted")
        #expect(result["error"]?.stringValue == "notifications-unsupported-host")
    }
}
