import Foundation
import AGUIKit

/// Stable, cache-friendly summary of a MyApp's canvas. Replaces the full
/// `CanvasSnapshot` JSON that ChatViewModel used to ship in the
/// "Live canvas state" context entry every turn.
///
/// The summary is intentionally **thin** — just enough for the agent to
/// enumerate what exists and pivot into a discovery tool when it needs
/// more. Per component: `id`, `name`, `kind`, `size` (a coarse
/// cache-stable bucket, not an exact count), and the LLM-authored
/// `summary` slot. Schema, view modes, filter, and item
/// previews are NOT in here — fetch them on demand via the kind's
/// discovery tools (`listTrackerItems`, `getTrackerItem`, …) or fall
/// back to `getCanvasState`.
///
/// `summary` is **always emitted** (as `null` when unset) so the agent
/// sees the empty slot and knows it can fill it. The slot is purely
/// LLM-populated — the app never auto-builds it. The agent writes to it
/// by calling the kind's render tool with only `summary` populated
/// (`renderTracker(summary: "…")` etc.); the slot then round-trips back
/// in the canvas summary on every subsequent turn until the agent
/// overwrites it.
///
/// The **active** (on-screen) component is deliberately NOT here. It is a
/// pure view pointer that changes as the user browses, so carrying it
/// would bust the prompt cache every navigation — and tools no longer
/// target it, so the agent doesn't need it by default. When the agent
/// genuinely needs "the one the user is looking at" it fetches it on
/// demand via the `getActiveComponent` tool.
public struct CanvasSummary: Encodable, Sendable {
    public let components: [ComponentSummary]

    public init(components: [ComponentSummary]) {
        self.components = components
    }

    /// Build a summary of `myApp`. The `previewTracker` argument is
    /// retained for now to keep the call-site signatures stable; the
    /// summary itself no longer carries a per-component item preview.
    @MainActor
    public static func build(
        myApp: MyApp,
        previewTracker: CanvasPreviewTracker = CanvasPreviewTracker()
    ) -> CanvasSummary {
        _ = previewTracker
        let comps = myApp.components.map { ComponentSummary.build(component: $0) }
        return CanvasSummary(components: comps)
    }

    /// Encode this summary as a compact JSON string (sorted keys, no
    /// pretty-printing — sorted keys give deterministic output, which is
    /// what makes the prompt cache-friendly).
    public func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// One slot in `CanvasSummary.components`. Every field here is
/// cache-stable: `summary` only changes when the agent writes a new note,
/// and `size` is a **coarse bucket** ("empty" / "1-9" / "10-99" / "100+")
/// rather than an exact item count. The bucket is deliberate — an exact
/// count changes on every add/remove and, because this summary rides the
/// cached "Live canvas state" context entry on every turn, an exact count
/// busted the prompt cache on each mutation. The bucket only shifts at
/// order-of-magnitude boundaries, so most mutation turns keep the cache
/// warm. The agent fetches exact counts on demand via the discovery tools
/// (`listTrackerItems` etc. return `totalItems`).
public struct ComponentSummary: Encodable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let size: String
    /// LLM-authored content summary. Always emitted (encoded as `null`
    /// when unset) so the agent sees the empty slot and knows it can
    /// fill it via the kind's render tool.
    public let summary: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, size, summary
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(size, forKey: .size)
        // ALWAYS emit summary so the slot is visible to the agent —
        // even when nil, the key must appear (encoded as JSON null).
        if let summary {
            try c.encode(summary, forKey: .summary)
        } else {
            try c.encodeNil(forKey: .summary)
        }
    }

    @MainActor
    static func build(component: Component) -> ComponentSummary {
        ComponentSummary(
            id: component.id,
            name: component.name,
            kind: component.body.kindString,
            size: sizeBucket(itemCount(of: component.body)),
            summary: component.summary
        )
    }

    /// Map an exact count onto a coarse, cache-stable bucket label.
    static func sizeBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "empty"
        case ..<10: return "1-9"
        case ..<100: return "10-99"
        default: return "100+"
        }
    }

    @MainActor
    private static func itemCount(of body: CanvasApp) -> Int {
        // Each kind counts its own items via its module (issue #162); `.empty`
        // has no module and counts as 0.
        ComponentRegistry.shared.module(forKind: body.kindString)?.itemCount(body) ?? 0
    }
}

/// Shared preview-rendering helpers. Same one-line renders used by the
/// stable canvas summary (`ComponentSummary`) and the progressive-discovery
/// tools (`listTrackerItems`, `searchTrackerItems`, etc.), so the agent
/// sees a consistent shape whether it's reading the summary or paginating
/// into a component.
public enum CanvasPreview {
    public static func fieldSummary(_ f: FieldDef) -> AnyJSON {
        var obj: [String: AnyJSON] = [
            "name": .string(f.name),
            "type": .string(f.type.rawValue),
        ]
        if let label = f.label { obj["label"] = .string(label) }
        if let options = f.options { obj["options"] = .array(options.map { .string($0) }) }
        if let hidden = f.hidden { obj["hidden"] = .bool(hidden) }
        return .object(obj)
    }

    /// One-line preview for a tracker row. `fieldNames`, when non-nil,
    /// restricts the preview to those field names (in the same order);
    /// otherwise every visible (non-hidden) field with a non-empty value
    /// is rendered.
    public static func trackerItem(
        _ item: TrackerItem,
        fields: [FieldDef],
        fieldNames: [String]? = nil
    ) -> String {
        let pool: [FieldDef]
        if let fieldNames {
            let order = fieldNames
            pool = order.compactMap { name in fields.first(where: { $0.name == name }) }
        } else {
            pool = fields.filter { !($0.hidden ?? false) }
        }
        let parts = pool.compactMap { field -> String? in
            guard let raw = item.values[field.name], !raw.isEmpty else { return nil }
            return "\(field.name)=\(truncateForPreview(raw))"
        }
        return parts.isEmpty ? "(empty)" : parts.joined(separator: ", ")
    }

    public static func calendarEvent(_ event: CalendarEvent) -> String {
        var s = "\(truncateForPreview(event.title)) @ \(event.start)"
        if let location = event.location, !location.isEmpty {
            s += " — \(truncateForPreview(location))"
        }
        return s
    }

    public static func checklistItem(_ item: ChecklistItem) -> String {
        let box = item.done ? "[x]" : "[ ]"
        return "\(box) \(truncateForPreview(item.text))"
    }
}

/// One entry in `ComponentSummary.preview`. `id` is the underlying item's
/// stable UUID string so the agent can pivot from the preview to a full
/// `get*` call. `summary` is a compact one-line render — long values are
/// already cut with `[PREVIEW END]`.
public struct PreviewItem: Encodable, Sendable {
    public let id: String
    public let summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

/// Truncate `s` to `budget` characters, appending ` [PREVIEW END]` when
/// the string was cut. Below-budget strings are returned unchanged. The
/// marker is a fixed sentinel the agent (and a human reader) can spot at
/// a glance so a partial value isn't mistaken for the full content.
public func truncateForPreview(_ s: String, budget: Int = 60) -> String {
    guard s.count > budget else { return s }
    let head = s.prefix(budget)
    return "\(head) [PREVIEW END]"
}

/// Picks a stable 2-item preview slate per component, holding ids across
/// turns so the prompt cache isn't busted by every unrelated mutation.
///
/// Behaviour, per call to `pickPreviewIds(componentId:availableIds:)`:
/// - Surviving sticky ids (still in `availableIds`) keep their slots.
/// - Empty slots are backfilled from `availableIds` in insertion order,
///   skipping ids already occupying another slot.
/// - The new slate is persisted and returned.
///
/// Lifetime is tied to the owning `ChatViewModel`. Cleared on "New
/// session" (no separate `reset()` needed — drop the instance to wipe).
@MainActor
public final class CanvasPreviewTracker {
    /// Max preview items per component. Two is enough for the agent to
    /// get a sense of the items' shape without bloating the summary.
    public static let slotCount: Int = 2

    private var stickyIds: [String: [String]] = [:]

    public init() {}

    public func pickPreviewIds(componentId: String, availableIds: [String]) -> [String] {
        let prior = stickyIds[componentId] ?? []
        let available = Set(availableIds)
        var picked = prior.filter { available.contains($0) }
        if picked.count < Self.slotCount {
            let needed = Self.slotCount - picked.count
            let occupied = Set(picked)
            let backfill = availableIds.filter { !occupied.contains($0) }.prefix(needed)
            picked.append(contentsOf: backfill)
        }
        stickyIds[componentId] = picked
        return picked
    }
}
