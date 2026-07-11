import Foundation

/// Append-only registry of `MyAppType`s the app knows how to render. The
/// built-in `tracker` type is registered at app bootstrap; future BYO types
/// can call `register(_:)` to add their own (see Phase C in the design doc).
@MainActor
public final class MyAppTypeRegistry {
    public static let shared = MyAppTypeRegistry()

    private var types: [MyAppType] = []

    private init() {}

    /// Register a type. Re-registering an id replaces the existing one.
    public func register(_ type: MyAppType) {
        if let idx = types.firstIndex(where: { $0.id == type.id }) {
            types[idx] = type
        } else {
            types.append(type)
        }
    }

    public func resolve(id: String) -> MyAppType? {
        types.first { $0.id == id }
    }

    public var allTypes: [MyAppType] { types }

    /// Idempotent — registers the built-in `tracker` type and its item policy
    /// if absent. Called from `AppView.init`.
    public func registerBuiltins() {
        if resolve(id: MyAppType.tracker.id) == nil {
            register(.tracker)
        }

        // Component modules — one self-registering module per kind (issue #162).
        // Migrated incrementally: registered kinds route through the module at
        // the inverted central sites; unregistered kinds fall back to the legacy
        // switches. `ComponentRegistry.assertComplete` is wired once every
        // supported kind ships a module.
        if !ComponentRegistry.shared.isRegistered(forKind: "tracker") {
            ComponentRegistry.shared.register(TrackerModule())
        }

        if !ItemPolicyRegistry.shared.isRegistered(forKind: "tracker") {
            ItemPolicyRegistry.shared.register(TrackerItemPolicy(), forKind: "tracker")
        }
        if !ItemPolicyRegistry.shared.isRegistered(forKind: "calendar") {
            ItemPolicyRegistry.shared.register(CalendarEventPolicy(), forKind: "calendar")
        }
        if !ItemPolicyRegistry.shared.isRegistered(forKind: "checklist") {
            ItemPolicyRegistry.shared.register(ChecklistItemPolicy(), forKind: "checklist")
        }

        // Marketplace export policies — one per supported component kind. Must
        // stay complete: `assertComplete` traps at bootstrap if a supported
        // kind is missing one (the export round-trip would otherwise silently
        // skip its records). New component? Register its policy here.
        let exportPolicies: [any ComponentExportPolicy] = [
            TrackerExportPolicy(), CalendarExportPolicy(), ChecklistExportPolicy(),
            SlackExportPolicy(), CalculatorExportPolicy(), ChartExportPolicy(),
        ]
        for policy in exportPolicies where !ComponentExportRegistry.shared.isRegistered(forKind: policy.kind) {
            ComponentExportRegistry.shared.register(policy, forKind: policy.kind)
        }
        let supportedKinds = allTypes.reduce(into: Set<String>()) { $0.formUnion($1.supportedComponentKinds) }
        ComponentExportRegistry.shared.assertComplete(supportedKinds: supportedKinds)
    }
}
