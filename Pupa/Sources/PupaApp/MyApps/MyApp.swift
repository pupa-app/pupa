import Foundation

/// One row in the sidebar. Each myApp owns its own chat thread list and a list
/// of components (a tracker, a calendar, …) displayed under it in the sidebar.
/// MyApps of the same `typeId` share a tool surface and a system-prompt
/// fragment (resolved via `MyAppTypeRegistry`).
public struct MyApp: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var iconSystemName: String
    public var typeId: String
    /// Ordered list of components rendered under this MyApp. Each component
    /// has a stable string id (e.g. `"tracker-1"`, `"calendar-1"`) the agent
    /// can address. New MyApps start with a single component matching
    /// `typeId`; the agent (or user) can add more via `addComponent`.
    public var components: [Component]
    /// Stable string id of the component currently focused in the canvas.
    /// `nil` means "fall back to the first component". Sidebar selection
    /// updates this so the right tools target the right component.
    public var activeComponentId: String?
    /// Ordered list of chat threads for this myApp. Always non-empty.
    public var threads: [ChatThread]
    /// The threadId of the currently-selected conversation.
    public var currentThreadId: String
    public let createdAt: Date
    /// Per-MyApp settings overrides. Keys are `SettingsKey.name` values.
    public var settings: [String: SettingValue]
    /// Archived (hidden) apps leave the sidebar and every agent-facing app
    /// list; their components are locked. Restored from Settings → Archive.
    public var isArchived: Bool
    /// Locks this app's whole memory subtree: the agent's memory-write tools
    /// and the Memories UI refuse every mutation (read stays open) until the
    /// user unlocks. The memory counterpart of the per-component lock.
    public var isMemoryLocked: Bool
    /// Stable palette slot for this app's accent color, resolved through
    /// `Color.color(atIndex:)`. Assigned once at creation and never derived
    /// from list position, so deleting another app never slides this app's
    /// color onto a neighbour. `nil` on apps saved before this field existed;
    /// `MyAppStore` backfills those from creation order on load. User-settable
    /// (the color is choosable), so it is decoupled from creation order.
    public var colorIndex: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        iconSystemName: String,
        typeId: String,
        components: [Component]? = nil,
        activeComponentId: String? = nil,
        threads: [ChatThread]? = nil,
        currentThreadId: String? = nil,
        createdAt: Date = Date(),
        settings: [String: SettingValue] = [:],
        isArchived: Bool = false,
        isMemoryLocked: Bool = false,
        colorIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.typeId = typeId
        if let provided = components, !provided.isEmpty {
            self.components = provided
        } else {
            self.components = [
                Component(
                    id: "\(typeId)-1",
                    name: typeId.capitalized,
                    iconSystemName: iconSystemName,
                    body: .empty
                )
            ]
        }
        self.activeComponentId = activeComponentId ?? self.components.first?.id
        let initialThread = threads?.first ?? ChatThread(createdAt: createdAt)
        self.threads = threads ?? [initialThread]
        self.currentThreadId = currentThreadId ?? self.threads[0].id
        self.createdAt = createdAt
        self.settings = settings
        self.isArchived = isArchived
        self.isMemoryLocked = isMemoryLocked
        self.colorIndex = colorIndex
    }

    // MARK: - Component access

    /// The currently-selected component (falls back to first). All canvas
    /// mutators route through here when no specific component id is given.
    public var activeComponent: Component? {
        if let id = activeComponentId,
           let c = components.first(where: { $0.id == id }) {
            return c
        }
        return components.first
    }

    public func component(withId id: String) -> Component? {
        components.first(where: { $0.id == id })
    }

    public var canvas: CanvasApp {
        get { activeComponent?.body ?? .empty }
        set {
            let targetId = activeComponentId ?? components.first?.id
            guard let targetId,
                  let idx = components.firstIndex(where: { $0.id == targetId }) else { return }
            components[idx].body = newValue
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, iconSystemName, typeId, components, activeComponentId
        case threads, currentThreadId, createdAt, settings, isArchived, isMemoryLocked
        case colorIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.iconSystemName = try c.decode(String.self, forKey: .iconSystemName)
        self.typeId = try c.decode(String.self, forKey: .typeId)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.settings = (try? c.decodeIfPresent([String: SettingValue].self, forKey: .settings)) ?? [:]
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.isMemoryLocked = try c.decodeIfPresent(Bool.self, forKey: .isMemoryLocked) ?? false
        self.colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
        self.components = try c.decode([Component].self, forKey: .components)
        self.activeComponentId = try c.decodeIfPresent(String.self, forKey: .activeComponentId)
            ?? self.components.first?.id
        self.threads = try c.decode([ChatThread].self, forKey: .threads)
        self.currentThreadId = try c.decode(String.self, forKey: .currentThreadId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(iconSystemName, forKey: .iconSystemName)
        try c.encode(typeId, forKey: .typeId)
        try c.encode(components, forKey: .components)
        try c.encodeIfPresent(activeComponentId, forKey: .activeComponentId)
        try c.encode(threads, forKey: .threads)
        try c.encode(currentThreadId, forKey: .currentThreadId)
        try c.encode(createdAt, forKey: .createdAt)
        if !settings.isEmpty { try c.encode(settings, forKey: .settings) }
        if isArchived { try c.encode(isArchived, forKey: .isArchived) }
        if isMemoryLocked { try c.encode(isMemoryLocked, forKey: .isMemoryLocked) }
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
    }
}
