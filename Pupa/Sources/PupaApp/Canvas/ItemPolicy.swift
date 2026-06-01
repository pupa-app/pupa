import Foundation

/// Non-generic slice of an item policy — guardrails that don't depend on the
/// specific item type. Stored in `ItemPolicyRegistry` keyed by kind string so
/// `MyAppStore` mutators can consult them without knowing the concrete type.
///
/// `onItemRemoved` is `@MainActor` because implementations will call store
/// mutators (e.g. `cascadeRemoveRefs`) which require main-actor isolation.
/// The default implementation is a no-op; Phase 2–4 policy types override it
/// to route removal cascades through the registry instead of the kind-switch
/// that currently lives in `MyAppStore.cascadeRemoveRefs`.
public protocol AnyItemPolicy: Sendable {
    var maxLinkedItems: Int { get }
    var maxDisplayNameLength: Int { get }
    func canLinkTo(targetKind: String) -> Bool
    @MainActor func onItemRemoved(itemId: UUID, from store: MyAppStore, myAppId: UUID?)
}

public extension AnyItemPolicy {
    @MainActor func onItemRemoved(itemId: UUID, from store: MyAppStore, myAppId: UUID?) {}
}

/// Full item policy — adds a typed `validate` method on top of the generic
/// `AnyItemPolicy` operations. Concrete policy types (e.g. `TrackerItemPolicy`)
/// conform here; the store stores the type-erased `any AnyItemPolicy` form.
public protocol ItemPolicy: AnyItemPolicy {
    associatedtype ItemType: Item
    func validate(_ item: ItemType) -> [ItemValidationError]
}

public extension ItemPolicy {
    func validate(_ item: ItemType) -> [ItemValidationError] { [] }
}

/// Dispatch table mapping kind strings to their registered policies. Consulted
/// by `MyAppStore.linkItems` (canLinkTo gating) and by removal cascade routing
/// once Phases 2–4 land. Policies are registered at app startup alongside
/// `MyAppTypeRegistry.registerBuiltins()`.
@MainActor
public final class ItemPolicyRegistry {
    public static let shared = ItemPolicyRegistry()

    private var table: [String: any AnyItemPolicy] = [:]

    public init() {}

    public func register(_ policy: any AnyItemPolicy, forKind kind: String) {
        table[kind] = policy
    }

    public func policy(forKind kind: String) -> (any AnyItemPolicy)? {
        table[kind]
    }

    public func isRegistered(forKind kind: String) -> Bool {
        table[kind] != nil
    }

    public var registeredKinds: Set<String> {
        Set(table.keys)
    }
}
