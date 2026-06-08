import Foundation

/// A component kind's export/import contract — the *code* that strips user
/// records on export, dispatched by `kind`. The bundle itself is pure data;
/// rebuild logic lives here in the app. Adding a component kind requires
/// registering one (enforced by `ComponentExportRegistry.assertComplete`).
///
/// Cross-component reference handling is **not** here — that lives once on
/// `CanvasApp.componentReferences` / `remapReferences`, shared with the delete
/// cascade. A policy only owns what's genuinely export-specific.
@MainActor
public protocol ComponentExportPolicy: Sendable {
    /// The `CanvasApp.kindString` this policy applies to.
    var kind: String { get }

    /// EXPORT (records off): drop user-entered records, keep the reusable
    /// structure (schema / formulas / personas). Returns the sanitised body.
    /// Bodies of a different kind are returned untouched.
    func strippingUserData(_ body: CanvasApp) -> CanvasApp

    /// Caveat shown on the export sheet when data can't be fully stripped
    /// (`nil` = a clean template). e.g. Slack keeps agent personas.
    var exportDataWarning: String? { get }
}

public extension ComponentExportPolicy {
    var exportDataWarning: String? { nil }
}

/// Registry of per-kind export policies. Mirrors `ItemPolicyRegistry`: a
/// `@MainActor` singleton, keyed by kind string, registered at bootstrap in
/// `MyAppTypeRegistry.registerBuiltins()`.
@MainActor
public final class ComponentExportRegistry {
    public static let shared = ComponentExportRegistry()

    private var table: [String: any ComponentExportPolicy] = [:]

    public init() {}

    public func register(_ policy: any ComponentExportPolicy, forKind kind: String) {
        table[kind] = policy
    }

    public func policy(forKind kind: String) -> (any ComponentExportPolicy)? {
        table[kind]
    }

    public func isRegistered(forKind kind: String) -> Bool {
        table[kind] != nil
    }

    public var registeredKinds: Set<String> { Set(table.keys) }

    /// Strip a body via its kind's policy; bodies with no policy (e.g.
    /// `empty`) pass through untouched.
    public func strippingUserData(_ body: CanvasApp) -> CanvasApp {
        policy(forKind: body.kindString)?.strippingUserData(body) ?? body
    }

    /// Fail fast at bootstrap if any supported component kind lacks an export
    /// policy — so a new kind can't ship export-broken. Uses
    /// `preconditionFailure` (survives release builds, unlike `assert`); the
    /// CI completeness test catches it earlier still.
    public func assertComplete(supportedKinds: Set<String>) {
        // `empty` is a placeholder body with no exportable data and no policy.
        let required = supportedKinds.subtracting(["empty"])
        let missing = required.subtracting(registeredKinds)
        if !missing.isEmpty {
            preconditionFailure(
                "Component kinds \(missing.sorted()) are in supportedComponentKinds "
                + "but have no ComponentExportPolicy. Register one in "
                + "MyAppTypeRegistry.registerBuiltins().")
        }
    }
}
