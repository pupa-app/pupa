import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins the cross-myApp isolation guard on the `sendNotification` tool: a
/// MyApp may only deep-link a notification back into ITSELF, never into a
/// sibling MyApp. The reject path returns before `coordinator.schedule`, so it
/// never touches `UNUserNotificationCenter` and is safe in this test process.
@Suite("Notification cross-myApp isolation")
@MainActor
struct NotificationIsolationTests {

    private func sendNotificationTool(ownerMyAppId: UUID?) -> ClientTool {
        let registry = ToolRegistry()
        AppTools.registerNotificationTools(
            on: registry,
            coordinator: .shared,
            toolGateState: ToolGateState(),
            ownerMyAppId: ownerMyAppId
        )
        // Force-unwrap: registration always adds `sendNotification`.
        return registry.resolve("sendNotification")!
    }

    private func baseArgs(target: UUID?) -> AnyJSON {
        var obj: [String: AnyJSON] = [
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
        ]
        if let target {
            obj["target"] = .object(["myAppId": .string(target.uuidString)])
        }
        return .object(obj)
    }

    @Test("rejects a target pointing at a different myApp")
    func rejectsForeignTarget() async throws {
        let owner = UUID()
        let other = UUID()
        let result = try await sendNotificationTool(ownerMyAppId: owner)
            .handler(baseArgs(target: other))
        #expect(result["ok"]?.boolValue == false)
        #expect(result["error"]?.stringValue == "notification-target-not-permitted")
    }

    @Test("a component-scoped foreign target is still rejected")
    func rejectsForeignComponentTarget() async throws {
        let owner = UUID()
        let other = UUID()
        let args: AnyJSON = .object([
            "title": .string("hi"),
            "body": .string("there"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object([
                "myAppId": .string(other.uuidString),
                "componentId": .string("tracker-1"),
            ]),
        ])
        let result = try await sendNotificationTool(ownerMyAppId: owner).handler(args)
        #expect(result["ok"]?.boolValue == false)
        #expect(result["error"]?.stringValue == "notification-target-not-permitted")
    }

    @Test("orchestrator scope (nil owner) does not reject a foreign target at the guard")
    func orchestratorGuardIsPermissive() async throws {
        // With no owner, the isolation guard must NOT fire. We assert the
        // result is not the isolation rejection; scheduling itself may still
        // fail on the unsupported test host, which is a different error.
        let result = try await sendNotificationTool(ownerMyAppId: nil)
            .handler(baseArgs(target: UUID()))
        #expect(result["error"]?.stringValue != "notification-target-not-permitted")
    }
}
