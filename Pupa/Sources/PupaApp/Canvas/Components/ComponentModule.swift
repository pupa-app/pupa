import SwiftUI
import AGUIKit

/// Everything a session's tool registration needs, in one bag. A
/// `ComponentModule` reads only the slots its kind uses (tracker: `store` +
/// `myAppId`; slack: also `memory` + `slack`). Mirrors the argument list of
/// `AppTools.registerMyAppTools` so a module's `registerTools` is a thin
/// forward to the existing `AppTools.register<Kind>Tools`.
@MainActor
public struct ComponentToolContext {
    public let store: MyAppStore
    public let myAppId: UUID
    public let memory: MemoryStore?
    public let slack: AppTools.SlackToolContext?

    public init(
        store: MyAppStore,
        myAppId: UUID,
        memory: MemoryStore? = nil,
        slack: AppTools.SlackToolContext? = nil
    ) {
        self.store = store
        self.myAppId = myAppId
        self.memory = memory
        self.slack = slack
    }
}

/// One self-registering canvas component kind. Collapses the per-kind
/// registration that used to be smeared across `CanvasView`, `CanvasSummary`,
/// `CanvasState`, `AppTools`, `MyAppType`, and three separate registries into a
/// single type a contributor writes once. Mirrors `ItemPolicyRegistry` /
/// `ComponentExportRegistry`: `@MainActor`, keyed by the lowercase `kind`
/// string, registered at bootstrap in `MyAppTypeRegistry.registerBuiltins()`.
///
/// The `CanvasApp` Codable enum stays the persistence discriminator (the Tier 1
/// boundary) — each module does its own single-case unwrap
/// (`guard case .tracker(let d) = body`) instead of the central exhaustive
/// switch, so a module owns only its own case.
@MainActor
public protocol ComponentModule: Sendable {
    /// Lowercase kind string, matching `CanvasApp.kindString` (`"tracker"`).
    var kind: String { get }
    /// Tools + prompt prose + catalog blurb for this kind (was a
    /// `MyAppType.kinds[…]` literal).
    var kindSpec: ComponentKindSpec { get }
    /// SF Symbol seeded onto a freshly added component (was
    /// `AppTools.defaultIcon(forKind:)`).
    var defaultIcon: String { get }

    /// Empty typed body for a new component of this kind (was
    /// `CanvasApp.emptyBody(forKind:)`).
    func makeEmptyBody() -> CanvasApp
    /// Item count for the canvas summary size bucket (was
    /// `CanvasSummary.itemCount(of:)`). Returns 0 for a body of another kind.
    func itemCount(_ body: CanvasApp) -> Int
    /// Empty-state copy for the canvas placeholder (was the `EmptyComponentHint`
    /// switches in `CanvasView`).
    func emptyHint() -> (headline: String, subline: String)
    /// The component's canvas view. `coordinator` is only used by slack; other
    /// kinds ignore it.
    func makeView(
        component: Component,
        store: MyAppStore,
        myAppId: UUID,
        coordinator: ChatSessionCoordinator?
    ) -> AnyView

    /// Link/removal guardrails, or `nil` for kinds with no link-bearing items
    /// (slack / calculator / chart).
    var itemPolicy: (any AnyItemPolicy)? { get }
    /// Export/import strip-and-rebuild contract.
    var exportPolicy: any ComponentExportPolicy { get }
    /// Register this kind's frontend tools on a session's registry — forwards to
    /// the existing `AppTools.register<Kind>Tools`.
    func registerTools(on registry: ToolRegistry, context: ComponentToolContext)
}

public extension ComponentModule {
    var itemPolicy: (any AnyItemPolicy)? { nil }
}

/// Dispatch table mapping kind strings to their `ComponentModule`. The single
/// spine the inverted central sites (`CanvasView`, `CanvasSummary`,
/// `CanvasState.emptyBody`, `AppTools.defaultIcon`) look up instead of
/// switching on the enum. Mirrors `ItemPolicyRegistry` /
/// `ComponentExportRegistry`; populated at bootstrap in
/// `MyAppTypeRegistry.registerBuiltins()`.
@MainActor
public final class ComponentRegistry {
    public static let shared = ComponentRegistry()

    private var table: [String: any ComponentModule] = [:]

    public init() {}

    /// Register (or replace) a module under its own `kind`.
    public func register(_ module: any ComponentModule) {
        table[module.kind] = module
    }

    public func module(forKind kind: String) -> (any ComponentModule)? {
        table[kind]
    }

    public func isRegistered(forKind kind: String) -> Bool {
        table[kind] != nil
    }

    public var registeredKinds: Set<String> { Set(table.keys) }

    public var allModules: [any ComponentModule] { Array(table.values) }

    /// Fail fast at bootstrap if a supported kind has no module — the runtime
    /// replacement for the enum's compile-time exhaustiveness on the inverted
    /// sites. Not called until every supported kind ships a module (Tier 1
    /// completes); during the incremental migration unregistered kinds fall
    /// back to the legacy switches.
    public func assertComplete(supportedKinds: Set<String>) {
        // `empty` is a placeholder body with no module.
        let required = supportedKinds.subtracting(["empty"])
        let missing = required.subtracting(registeredKinds)
        if !missing.isEmpty {
            preconditionFailure(
                "Component kinds \(missing.sorted()) are in supportedComponentKinds "
                + "but have no ComponentModule. Register one in "
                + "MyAppTypeRegistry.registerBuiltins().")
        }
    }
}
