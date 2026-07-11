import Foundation

// Tracker component data model. Moved out of the CanvasState monolith into
// the Tracker component folder (issue #162). The `CanvasApp.tracker` enum arm
// and its Codable stay in CanvasState — the persistence discriminator.

public enum FieldType: String, Codable, Sendable {
    case text
    case number
    case select
    /// A URL or emoji that the card grid renders as a hero. Stored as a
    /// `[String: String]` value like every other field — the view layer decides
    /// how to display it.
    case image
    /// A URL the user wants quick access to (Amazon product page, recipe
    /// source, GitHub repo, …). Rendered on each card as a clickable pill
    /// that opens the URL in the default browser. Stored as a plain string;
    /// invalid URLs fall back to a non-clickable text pill.
    case link
}

public struct FieldDef: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String?
    public var type: FieldType
    public var options: [String]?
    /// When `true`, the field disappears from form / card / filter / kanban
    /// group-by UI but its values are kept on every item so unhide is fully
    /// reversible. Soft-hide is the only "remove" verb on a tracker field —
    /// hard removal would orphan item data, which is incompatible with the
    /// "items are hard to delete" invariant. `nil` decodes as visible.
    public var hidden: Bool?
    public var id: String { name }

    public init(
        name: String,
        label: String? = nil,
        type: FieldType,
        options: [String]? = nil,
        hidden: Bool? = nil
    ) {
        self.name = name
        self.label = label
        self.type = type
        self.options = options
        self.hidden = hidden
    }
}

/// One row in a tracker. `id` is stable across every schema mutation so the
/// agent (and SwiftUI) can refer to a row without depending on its array
/// position. `values` is sparse — a missing key for any field is treated as
/// empty by the view layer, which is what lets `addTrackerField` /
/// `hideTrackerField` etc. mutate `TrackerData.fields` without ever touching
/// items.
///
/// `linkedItems` (added in project `0.0.41`) holds inline references to
/// items in other components (tracker rows, calendar events, or other
/// checklist rows). Each ref renders as a chain-link pill on the row's
/// card; deleting the target sweeps the ref via
/// `MyAppStore.cascadeRemoveRefs`.
public struct TrackerItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var values: [String: String]
    public var linkedItems: [ComponentItemRef]

    public init(
        id: UUID = UUID(),
        values: [String: String],
        linkedItems: [ComponentItemRef] = []
    ) {
        self.id = id
        self.values = values
        self.linkedItems = linkedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, values, linkedItems, schemaVersion
    }

    /// Backward-compatible decoder. `linkedItems` defaults to empty when
    /// absent so on-disk blobs from before `0.0.41` decode cleanly.
    /// `schemaVersion` is read but not acted on here; migrations are applied
    /// at a higher level via `MigrationRegistry` before decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.values = try c.decode([String: String].self, forKey: .values)
        self.linkedItems = try c.decodeIfPresent([ComponentItemRef].self, forKey: .linkedItems) ?? []
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(values, forKey: .values)
        try c.encode(linkedItems, forKey: .linkedItems)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}

extension TrackerItem: Item {
    public static var kind: String { "tracker" }

    /// Best-effort display name for pills and pickers. Prefers well-known
    /// keys ("title", "name", "label") then falls back to the first
    /// non-empty value in sorted-key order. Callers with full field
    /// metadata should prefer `MyAppStore.displayNameForTrackerItem`.
    public var displayName: String {
        let preferred = ["title", "name", "label", "text"]
        for key in preferred {
            if let v = values[key]?.nonEmpty { return v }
        }
        return values.sorted(by: { $0.key < $1.key })
                     .first(where: { $0.value.nonEmpty != nil })?
                     .value ?? "–"
    }
}

/// How a tracker renders its items. Same underlying `TrackerData` —
/// only the SwiftUI view differs. Switching modes is non-destructive.
public enum TrackerViewMode: String, Codable, Hashable, Sendable {
    case grid    // adaptive card grid (default)
    case kanban  // Jira-style swimlanes grouped by a select field's options
}

public struct TrackerData: Codable, Hashable, Sendable {
    public var title: String
    public var fields: [FieldDef]
    /// Stable-id rows. Each `TrackerItem.values` is sparse `[String: String]`
    /// keyed by `FieldDef.name`; missing keys are treated as empty at the
    /// view layer, which is what lets the field-schema mutators stay
    /// non-destructive to existing items.
    public var items: [TrackerItem]
    public var filter: [String: String]
    public var viewMode: TrackerViewMode
    /// Name of the `select` field whose options are used as kanban columns when
    /// `viewMode == .kanban`. Nil means "auto-pick first eligible select field"
    /// at switch time. Retained across grid/kanban toggles so the user's
    /// column choice survives.
    public var columnField: String?

    public init(
        title: String,
        fields: [FieldDef],
        items: [TrackerItem] = [],
        filter: [String: String] = [:],
        viewMode: TrackerViewMode = .grid,
        columnField: String? = nil
    ) {
        self.title = title
        self.fields = fields
        self.items = items
        self.filter = filter
        self.viewMode = viewMode
        self.columnField = columnField
    }

    /// Non-hidden fields only. Every UI read site (form, card, filter,
    /// kanban group-by, "usable select" guards) should walk this — hidden
    /// fields keep their item values but disappear from the UI.
    public var visibleFields: [FieldDef] {
        fields.filter { !($0.hidden ?? false) }
    }

    enum CodingKeys: String, CodingKey {
        case title, fields, items, filter, viewMode, columnField
    }

    /// Custom decoder. Handles two backward-compat concerns:
    /// - Pre-`viewMode` blobs default `viewMode` / `columnField` to `.grid` / `nil`.
    /// - Pre-stable-id blobs stored `items` as `[[String: String]]`; we probe
    ///   for that shape first and stamp fresh UUIDs once at decode time
    ///   (never lazily — lazy assignment would regenerate IDs on every relaunch
    ///   and silently re-key UI state). The next `persist()` writes the new
    ///   `[TrackerItem]` shape and the legacy branch never runs again for
    ///   that blob.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.fields = try c.decode([FieldDef].self, forKey: .fields)
        self.items = (try? c.decodeIfPresent([TrackerItem].self, forKey: .items)) ?? []
        self.filter = try c.decodeIfPresent([String: String].self, forKey: .filter) ?? [:]
        self.viewMode = try c.decodeIfPresent(TrackerViewMode.self, forKey: .viewMode) ?? .grid
        self.columnField = try c.decodeIfPresent(String.self, forKey: .columnField)
    }
}
