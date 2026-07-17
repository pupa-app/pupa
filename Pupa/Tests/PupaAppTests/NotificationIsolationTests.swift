import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins the cross-myApp isolation guard on `sendNotification`. A MyApp (or a
/// sub-run acting for one) is `ownerMyAppId`-scoped and must not be able to
/// influence a *different* scope — the security property behind
/// pupa-backend#72. Two escape paths are covered:
///
///  1. a `target` pointing at a sibling MyApp (open/message another app), and
///  2. a targetless `populateChat`/`runAgent` tap, which would otherwise fire
///     its prompt on whatever chat scope is *active* at tap time.
///
/// The decision is a pure function (`AppTools.scopeNotificationRequest`), so we
/// test it directly — no `UNUserNotificationCenter`, works on the test host.
@Suite("Notification cross-myApp isolation")
@MainActor
struct NotificationIsolationTests {

    private func request(
        target: UUID?,
        componentId: String? = nil,
        tapAction: NotificationRequest.TapAction = .foreground
    ) -> NotificationRequest {
        NotificationRequest(
            title: "hi",
            body: "there",
            trigger: .now,
            target: target.map { NotificationRequest.Target(myAppId: $0, componentId: componentId) },
            tapAction: tapAction
        )
    }

    // MARK: - Reject: opening / messaging a sibling MyApp

    @Test("rejects a target pointing at a different myApp")
    func rejectsForeignTarget() {
        let owner = UUID()
        let decision = AppTools.scopeNotificationRequest(request(target: UUID()), ownerMyAppId: owner)
        #expect(decision == .rejectForeignTarget)
    }

    @Test("a component-scoped foreign target is still rejected")
    func rejectsForeignComponentTarget() {
        let owner = UUID()
        let decision = AppTools.scopeNotificationRequest(
            request(target: UUID(), componentId: "tracker-1", tapAction: .runAgent(prompt: "x")),
            ownerMyAppId: owner
        )
        #expect(decision == .rejectForeignTarget)
    }

    // MARK: - Allow: a myApp targeting itself

    @Test("a self-targeted notification is allowed unchanged")
    func allowsSelfTarget() {
        let owner = UUID()
        let req = request(target: owner, tapAction: .runAgent(prompt: "log my weight"))
        #expect(AppTools.scopeNotificationRequest(req, ownerMyAppId: owner) == .allow(req))
    }

    // MARK: - Close the escape: targetless injecting taps

    @Test("a targetless runAgent tap is pinned to the owner, not the active scope")
    func scopesTargetlessRunAgentToOwner() {
        let owner = UUID()
        let req = request(target: nil, tapAction: .runAgent(prompt: "do x"))
        guard case .allow(let scoped) = AppTools.scopeNotificationRequest(req, ownerMyAppId: owner) else {
            Issue.record("expected .allow with a coerced target")
            return
        }
        // The fix: the tap now navigates into the owner FIRST, so the prompt
        // runs in the owner's own chat — never on whatever scope was active.
        #expect(scoped.target?.myAppId == owner)
        #expect(scoped.tapAction == .runAgent(prompt: "do x"))
    }

    @Test("a targetless populateChat tap is pinned to the owner")
    func scopesTargetlessPopulateChatToOwner() {
        let owner = UUID()
        let req = request(target: nil, tapAction: .populateChat(prompt: "draft this"))
        guard case .allow(let scoped) = AppTools.scopeNotificationRequest(req, ownerMyAppId: owner) else {
            Issue.record("expected .allow with a coerced target")
            return
        }
        #expect(scoped.target?.myAppId == owner)
    }

    @Test("a bare targetless foreground notification stays targetless (nothing injected)")
    func leavesTargetlessForegroundAlone() {
        let owner = UUID()
        let req = request(target: nil, tapAction: .foreground)
        #expect(AppTools.scopeNotificationRequest(req, ownerMyAppId: owner) == .allow(req))
    }

    // MARK: - Orchestrator scope (nil owner) is unrestricted

    @Test("orchestrator scope (nil owner) may target any myApp and run any tap")
    func orchestratorScopeUnrestricted() {
        let req = request(target: UUID(), tapAction: .runAgent(prompt: "x"))
        #expect(AppTools.scopeNotificationRequest(req, ownerMyAppId: nil) == .allow(req))
    }

    // MARK: - Handler wiring: the tool actually returns the rejection

    @Test("the sendNotification handler surfaces the rejection for a foreign target")
    func handlerRejectsForeignTarget() async throws {
        let registry = ToolRegistry()
        let owner = UUID()
        AppTools.registerNotificationTools(
            on: registry,
            coordinator: .shared,
            toolGateState: ToolGateState(),
            ownerMyAppId: owner
        )
        let tool = registry.resolve("sendNotification")!
        let args: AnyJSON = .object([
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object(["myAppId": .string(UUID().uuidString)]),
        ])
        let result = try await tool.handler(args)
        #expect(result["ok"]?.boolValue == false)
        #expect(result["error"]?.stringValue == "notification-target-not-permitted")
    }
}
