import Foundation

// Checklist component data model. Moved out of CanvasState (issue #162).
// The `CanvasApp.checklist` enum arm + its Codable stay in CanvasState.

/// One row in a checklist. `id` is stable across reorderings so the agent
/// (and SwiftUI) can refer to a row without depending on its array
/// position. `done` is the checkbox state; `text` the displayed line.
///
/// `linkedItems` attaches the row to zero or more items in other
/// components (today: tracker items and calendar events) — rendered as
/// inline chain-link pills under the row's text, with the linked item's
/// live display name pulled at render time. Deleting the target item
/// drops its ref from every checklist row's `linkedItems` automatically.
public struct ChecklistItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var done: Bool
    public var linkedItems: [ComponentItemRef]

    public init(
        id: UUID = UUID(),
        text: String,
        done: Bool = false,
        linkedItems: [ComponentItemRef] = []
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.linkedItems = linkedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, text, done, linkedItems, schemaVersion
    }

    /// Backward-compatible decoder. `linkedItems` defaults to empty when
    /// absent so any pre-link persisted blob decodes cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.text = try c.decode(String.self, forKey: .text)
        self.done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        self.linkedItems = try c.decodeIfPresent([ComponentItemRef].self, forKey: .linkedItems) ?? []
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(done, forKey: .done)
        try c.encode(linkedItems, forKey: .linkedItems)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}

extension ChecklistItem: Item {
    public static var kind: String { "checklist" }
    public var displayName: String { text.nonEmpty ?? "–" }
}

public struct ChecklistData: Codable, Hashable, Sendable {
    public var title: String
    public var items: [ChecklistItem]

    public init(title: String, items: [ChecklistItem] = []) {
        self.title = title
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case title, items
    }

    /// Backward-compatible decoder — `items` defaults to `[]` when
    /// absent so a freshly-seeded empty body decodes cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.items = try c.decodeIfPresent([ChecklistItem].self, forKey: .items) ?? []
    }
}
