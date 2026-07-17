import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins cross-myApp isolation on `sendNotification`. A notification's target is
/// bound to the scope of the agent that scheduled it — never to a value the
/// model supplies — so one myApp can't open or message another (pupa-backend#72).
///
/// Two layers are covered:
///  - **Parse** (`NotificationRequest.init(fromToolArgs:)`): a model-supplied
///    `target.myAppId` is ignored; only `componentId` survives.
///  - **Scope binding** (`AppTools.scopeNotificationRequest`): the owning myApp
///    is injected, foreground taps included; the orchestrator is left unchanged
///    (routed to its own chat at delivery time).
@Suite("Notification cross-myApp isolation")
@MainActor
struct NotificationIsolationTests {

    private func request(
        target: NotificationRequest.Target? = nil,
        tapAction: NotificationRequest.TapAction = .foreground
    ) -> NotificationRequest {
        NotificationRequest(title: "hi", body: "there", trigger: .now, target: target, tapAction: tapAction)
    }

    // MARK: - Parse: a model can't name a target myApp

    @Test("a model-supplied target.myAppId is ignored at parse")
    func parseIgnoresModelMyAppId() throws {
        let args: AnyJSON = .object([
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object([
                "myAppId": .string(UUID().uuidString),   // a sibling — must be dropped
                "componentId": .string("tracker-1"),
            ]),
        ])
        let parsed = try NotificationRequest(fromToolArgs: args)
        #expect(parsed.target?.myAppId == nil)
        #expect(parsed.target?.componentId == "tracker-1")
    }

    // MARK: - Scope binding: the owning myApp is injected

    @Test("a myApp notification is always bound to its own id — foreground taps too")
    func bindsForegroundToOwner() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(request(tapAction: .foreground), ownerMyAppId: owner)
        #expect(scoped.target?.myAppId == owner)
    }

    @Test("a runAgent tap is bound to the owner, never the active scope")
    func bindsRunAgentToOwner() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(
            request(tapAction: .runAgent(prompt: "do x")), ownerMyAppId: owner
        )
        #expect(scoped.target?.myAppId == owner)
        #expect(scoped.tapAction == .runAgent(prompt: "do x"))
    }

    @Test("a populateChat tap is bound to the owner")
    func bindsPopulateChatToOwner() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(
            request(tapAction: .populateChat(prompt: "draft this")), ownerMyAppId: owner
        )
        #expect(scoped.target?.myAppId == owner)
    }

    @Test("a chosen componentId is preserved while the myApp id is injected")
    func preservesComponentIdWhileBinding() {
        let owner = UUID()
        let scoped = AppTools.scopeNotificationRequest(
            request(target: .init(myAppId: nil, componentId: "tracker-1"), tapAction: .runAgent(prompt: "x")),
            ownerMyAppId: owner
        )
        #expect(scoped.target?.myAppId == owner)
        #expect(scoped.target?.componentId == "tracker-1")
    }

    // MARK: - Orchestrator scope (nil owner) is left for delivery-time routing

    @Test("orchestrator scope (nil owner) is returned unchanged")
    func orchestratorUnchanged() {
        let req = request(tapAction: .runAgent(prompt: "x"))
        let scoped = AppTools.scopeNotificationRequest(req, ownerMyAppId: nil)
        #expect(scoped == req)
        #expect(scoped.target?.myAppId == nil)
    }

    // MARK: - Handler wiring: no reject path remains; the request reaches scheduling

    @Test("the sendNotification handler binds and schedules (no target rejection)")
    func handlerBindsAndSchedules() async throws {
        let registry = ToolRegistry()
        AppTools.registerNotificationTools(
            on: registry,
            coordinator: .shared,
            toolGateState: ToolGateState(),
            ownerMyAppId: UUID()
        )
        let tool = registry.resolve("sendNotification")!
        let args: AnyJSON = .object([
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object(["myAppId": .string(UUID().uuidString)]),  // ignored, not rejected
        ])
        let result = try await tool.handler(args)
        // The old reject path is gone; on the test host (no bundle id) scheduling
        // reports `notifications-unsupported-host` — proof the request passed the
        // scope binding and reached `coordinator.schedule`.
        #expect(result["error"]?.stringValue != "notification-target-not-permitted")
        #expect(result["error"]?.stringValue == "notifications-unsupported-host")
    }
}
