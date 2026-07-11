import SwiftUI
import AGUIKit

/// The slack kind's `ComponentModule` (issue #162). Unlike the item-bearing
/// kinds, slack has no `itemPolicy` (messages aren't link targets), its view
/// needs the live `coordinator` (agent fan-out), and its tools register only
/// when a `SlackToolContext` is present.
@MainActor
public struct SlackModule: ComponentModule {
    public init() {}

    public let kind = "slack"
    public let defaultIcon = "bubble.left.and.bubble.right"

    /// Sourced from the `MyAppType.tracker.kinds` literal until the full #162
    /// pass inverts it (assembly-from-registry). Zero drift meanwhile.
    public var kindSpec: ComponentKindSpec {
        MyAppType.tracker.kinds["slack"]
            ?? ComponentKindSpec(tools: [], catalogBlurb: "slack")
    }

    // itemPolicy defaults to nil (protocol extension) — slack messages are not
    // link targets.
    public var exportPolicy: any ComponentExportPolicy { SlackExportPolicy() }

    public func makeEmptyBody() -> CanvasApp {
        .slack(SlackData())
    }

    public func itemCount(_ body: CanvasApp) -> Int {
        guard case .slack(let s) = body else { return 0 }
        return s.messagesByChannel.values.reduce(0) { $0 + $1.count }
    }

    public func emptyHint() -> (headline: String, subline: String) {
        (
            "This chat workspace is empty",
            "Ask the chat to set up channels and agents. Try \"Create a #standup channel with a PM and an engineer\"."
        )
    }

    public func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView {
        // Slack requires a live coordinator for agent fan-out; without one there
        // is nothing to render.
        guard case .slack(let data) = component.body, let coordinator else {
            return AnyView(EmptyView())
        }
        return AnyView(SlackView(
            store: store, data: data, myAppId: myAppId,
            componentId: component.id, coordinator: coordinator))
    }

    public func registerTools(on registry: ToolRegistry, context: ComponentToolContext) {
        guard let slack = context.slack else { return }
        AppTools.registerSlackTools(
            on: registry, store: context.store, myAppId: context.myAppId,
            memory: context.memory, context: slack)
    }
}
