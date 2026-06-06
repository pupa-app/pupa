import Foundation
import Observation

/// Top-level store for the user's myapps. Replaces the old singleton
/// `CanvasState` — every canvas mutation routes through here against the
/// active myapp.
///
/// Persistence is a single JSON blob under `pupa.myapps.v1`. On first
/// launch under a fresh install (or upgrade from any earlier `Space`-era
/// storage), `load()` seeds the pre-populated "Example: Wellbeing Coach"
/// workspace via `WellbeingCoachExample.make()` — a working demo of the
/// full canvas instead of an empty placeholder. Users can add any example
/// any time from Settings → Examples. The spaces→myapps rename in project
/// `0.0.26` is a clean break with no migration of older
/// `pupa.spaces.v1` / `pupa.canvas.v1` data.
/// The component refactor (project `0.0.31`) is backward-compatible at the
/// `MyApp` Codable layer — old single-`canvas` blobs are migrated on first
/// decode into a one-element `components` array.
@MainActor
@Observable
public final class MyAppStore {
    public static let storageKey = "pupa.myapps.v1"

    public private(set) var myApps: [MyApp]
    public private(set) var activeMyAppId: UUID
    /// Thread list for the Orchestrator (memory-scope) chat. Always non-empty.
    public private(set) var memoryThreads: [ChatThread]
    /// The threadId of the currently-selected Orchestrator conversation.
    public private(set) var memoryCurrentThreadId: String
    /// Append-only audit trail of item mutations. Persisted in the
    /// UserDefaults snapshot; live-observable so the History sheet updates.
    public private(set) var itemEventLog = ItemEventLog()
    /// Set to `true` while `undo(eventId:)` is executing so all emitted
    /// events during the inverse carry `isUndo: true` without changes to
    /// every mutator's public signature.
    private var undoInProgress = false

    public init(initial: ([MyApp], UUID)? = nil) {
        if let initial {
            self.myApps = initial.0
            self.activeMyAppId = initial.1
            let first = ChatThread()
            self.memoryThreads = [first]
            self.memoryCurrentThreadId = first.id
        } else {
            let snapshot = Self.load()
            self.myApps = snapshot.myApps
            self.activeMyAppId = snapshot.activeId
            self.memoryThreads = snapshot.memoryThreads
            self.memoryCurrentThreadId = snapshot.memoryCurrentThreadId
            self.itemEventLog = snapshot.itemEventLog
        }
    }

    // MARK: - Active myApp

    public var activeMyApp: MyApp {
        myApps.first(where: { $0.id == activeMyAppId }) ?? myApps[0]
    }

    /// Look up any myApp by id. Returns `nil` if not found.
    public func myApp(withId id: UUID) -> MyApp? {
        myApps.first(where: { $0.id == id })
    }

    /// Persist a per-MyApp settings override. Pass `nil` to clear the key.
    public func setMyAppSetting<K: SettingsKey>(
        _ key: K.Type,
        value: K.Value?,
        for myAppId: UUID
    ) where K.Value == Bool {
        guard let idx = myApps.firstIndex(where: { $0.id == myAppId }) else { return }
        if let value {
            myApps[idx].settings[K.name] = .bool(value)
        } else {
            myApps[idx].settings.removeValue(forKey: K.name)
        }
        persist()
    }

    /// Persist a per-MyApp settings override for a `String`-valued key. Pass `nil` to clear.
    public func setMyAppSetting<K: SettingsKey>(
        _ key: K.Type,
        value: K.Value?,
        for myAppId: UUID
    ) where K.Value == String {
        guard let idx = myApps.firstIndex(where: { $0.id == myAppId }) else { return }
        if let value, !value.isEmpty {
            myApps[idx].settings[K.name] = .string(value)
        } else {
            myApps[idx].settings.removeValue(forKey: K.name)
        }
        persist()
    }

    // MARK: - Per-agent LLM selection

    /// Storage key for the per-MyApp LLM provider ("bedrock" | "anthropic" | …).
    /// Paired with `LLMModelSettingsKey` — both must be present for the
    /// override to apply; either alone is treated as "no override" by the
    /// reader. Stored under `MyApp.settings`.
    public static let llmProviderSettingsKey = "llm.provider"
    /// Storage key for the per-MyApp LLM logical model id (e.g. "claude-sonnet-4-6").
    public static let llmModelSettingsKey = "llm.model"

    /// Write (or clear) the per-MyApp LLM override atomically. Pass `nil` for
    /// either field to clear both — the pair only ever applies together.
    public func setMyAppLLM(provider: String?, model: String?, for myAppId: UUID) {
        guard let idx = myApps.firstIndex(where: { $0.id == myAppId }) else { return }
        if let provider, let model, !provider.isEmpty, !model.isEmpty {
            myApps[idx].settings[Self.llmProviderSettingsKey] = .string(provider)
            myApps[idx].settings[Self.llmModelSettingsKey] = .string(model)
        } else {
            myApps[idx].settings.removeValue(forKey: Self.llmProviderSettingsKey)
            myApps[idx].settings.removeValue(forKey: Self.llmModelSettingsKey)
        }
        persist()
    }

    /// Read the per-MyApp LLM override. Returns `nil` when either field is
    /// missing — callers should fall back to the backend's env default.
    public func myAppLLM(for myAppId: UUID) -> (provider: String, model: String)? {
        guard let myApp = myApps.first(where: { $0.id == myAppId }) else { return nil }
        guard case .string(let provider) = myApp.settings[Self.llmProviderSettingsKey],
              case .string(let model) = myApp.settings[Self.llmModelSettingsKey] else { return nil }
        return (provider, model)
    }

    /// Write (or clear) the per-SlackAgent LLM override. The SlackAgent lives
    /// inside its parent `SlackData` — mutated in place via the by-component
    /// mutator so we touch only the targeted agent.
    public func setSlackAgentLLM(
        provider: String?,
        model: String?,
        componentId: String,
        agentId: String,
        myAppId: UUID
    ) {
        mutate(myAppId: myAppId, byComponentId: componentId) { canvas in
            guard case .slack(var s) = canvas,
                  let aIdx = s.agents.firstIndex(where: { $0.id == agentId }) else { return false }
            if let provider, let model, !provider.isEmpty, !model.isEmpty {
                s.agents[aIdx].llmProvider = provider
                s.agents[aIdx].llmModel = model
            } else {
                s.agents[aIdx].llmProvider = nil
                s.agents[aIdx].llmModel = nil
            }
            canvas = .slack(s)
            return true
        }
    }

    public func setActive(_ id: UUID) {
        guard myApps.contains(where: { $0.id == id }), id != activeMyAppId else { return }
        activeMyAppId = id
        persist()
    }

    // MARK: - Lifecycle

    @discardableResult
    public func addMyApp(typeId: String, name: String, iconSystemName: String) -> UUID {
        let myApp = MyApp(
            name: name.isEmpty ? "New myapp" : name,
            iconSystemName: iconSystemName,
            typeId: typeId
        )
        myApps.append(myApp)
        activeMyAppId = myApp.id
        persist()
        return myApp.id
    }

    public func renameMyApp(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = myApps.firstIndex(where: { $0.id == id }) else { return }
        guard myApps[idx].name != trimmed else { return }
        myApps[idx].name = trimmed
        persist()
    }

    public func removeMyApp(_ id: UUID) {
        guard myApps.count > 1, let idx = myApps.firstIndex(where: { $0.id == id }) else { return }
        myApps.remove(at: idx)
        if activeMyAppId == id {
            activeMyAppId = myApps[0].id
        }
        persist()
    }

    /// Re-insert the seeded "Example: Job Search" workspace if the user
    /// has deleted it. If a MyApp with `JobSearchExample.name` is already
    /// present, just makes it the active one — no duplicate is inserted.
    /// Wired into Settings → Examples → "Restore example MyApp".
    @discardableResult
    public func restoreExampleMyApp() -> UUID {
        restoreExample(JobSearchExample.self)
    }

    /// Generic restore for any `ExampleMyApp` conformance. Looks up an
    /// existing MyApp by name (idempotent — no duplicate if already present)
    /// or builds a fresh one via `example.make()` and appends it.
    @discardableResult
    public func restoreExample(_ example: any ExampleMyApp.Type) -> UUID {
        if let existing = myApps.first(where: { $0.name == example.name }) {
            if activeMyAppId != existing.id {
                activeMyAppId = existing.id
                persist()
            }
            return existing.id
        }
        let myApp = example.make()
        myApps.append(myApp)
        activeMyAppId = myApp.id
        persist()
        return myApp.id
    }

    // MARK: - Thread management

    public func threads(for scope: ChatScope) -> [ChatThread] {
        switch scope {
        case .memory: return memoryThreads
        case .myApp(let id): return myApps.first(where: { $0.id == id })?.threads ?? []
        }
    }

    public func currentThreadId(for scope: ChatScope) -> String {
        switch scope {
        case .memory: return memoryCurrentThreadId
        case .myApp(let id): return myApps.first(where: { $0.id == id })?.currentThreadId ?? UUID().uuidString
        }
    }

    public func setCurrentThread(_ threadId: String, for scope: ChatScope) {
        switch scope {
        case .memory:
            guard memoryThreads.contains(where: { $0.id == threadId }) else { return }
            memoryCurrentThreadId = threadId
        case .myApp(let id):
            guard let idx = myApps.firstIndex(where: { $0.id == id }),
                  myApps[idx].threads.contains(where: { $0.id == threadId }) else { return }
            myApps[idx].currentThreadId = threadId
        }
        persist()
    }

    /// Append a fresh `ChatThread`, make it current, persist, and return its id.
    @discardableResult
    public func addThread(for scope: ChatScope) -> String {
        let thread = ChatThread()
        switch scope {
        case .memory:
            memoryThreads.append(thread)
            memoryCurrentThreadId = thread.id
        case .myApp(let id):
            guard let idx = myApps.firstIndex(where: { $0.id == id }) else { return thread.id }
            myApps[idx].threads.append(thread)
            myApps[idx].currentThreadId = thread.id
        }
        persist()
        return thread.id
    }

    /// Set the title of a thread once — no-op if the thread already has a non-empty title.
    public func setThreadTitle(_ title: String, threadId: String, for scope: ChatScope) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch scope {
        case .memory:
            guard let idx = memoryThreads.firstIndex(where: { $0.id == threadId }),
                  memoryThreads[idx].title.isEmpty else { return }
            memoryThreads[idx].title = trimmed
        case .myApp(let id):
            guard let mIdx = myApps.firstIndex(where: { $0.id == id }),
                  let tIdx = myApps[mIdx].threads.firstIndex(where: { $0.id == threadId }),
                  myApps[mIdx].threads[tIdx].title.isEmpty else { return }
            myApps[mIdx].threads[tIdx].title = trimmed
        }
        persist()
    }

    /// Remove a thread. Picks a neighbour as current. Never leaves a scope with
    /// zero threads — auto-creates one if the last thread is removed.
    public func removeThread(_ threadId: String, for scope: ChatScope) {
        switch scope {
        case .memory:
            memoryThreads.removeAll(where: { $0.id == threadId })
            if memoryThreads.isEmpty { memoryThreads = [ChatThread()] }
            if !memoryThreads.contains(where: { $0.id == memoryCurrentThreadId }) {
                memoryCurrentThreadId = memoryThreads.last!.id
            }
        case .myApp(let id):
            guard let idx = myApps.firstIndex(where: { $0.id == id }) else { return }
            myApps[idx].threads.removeAll(where: { $0.id == threadId })
            if myApps[idx].threads.isEmpty { myApps[idx].threads = [ChatThread()] }
            if !myApps[idx].threads.contains(where: { $0.id == myApps[idx].currentThreadId }) {
                myApps[idx].currentThreadId = myApps[idx].threads.last!.id
            }
        }
        persist()
    }

    // MARK: - Component lifecycle

    /// Append a new component to `myAppId`. Two effects worth calling out:
    ///
    /// - **Empty placeholders are collapsed.** Any pre-existing component
    ///   whose body is `.empty` (most commonly the kindless seed dropped
    ///   in by `MyApp.init`) is removed before the new one is appended.
    ///   That's the contract that lets a fresh MyApp present "no
    ///   kind-specific tools yet" via the gated tool filter — when the
    ///   agent calls `addComponent`, the placeholder doesn't stick around
    ///   to muddy the sidebar alongside the new typed component.
    /// - **Body is seeded with an empty typed canvas matching `kind`** so
    ///   `Component.kindString` reflects the requested kind immediately —
    ///   the kind-gated tool surface (e.g. `renderCalendar`,
    ///   `addCalendarEvent`) is then advertised on the very next agent
    ///   round, before a render tool has been called. The kind-specific
    ///   render tool later replaces the body with a populated canvas.
    ///
    /// Unknown kinds fall back to `.empty` (won't contribute to the gated
    /// surface). Returns the generated stable id (e.g. `"calendar-2"`).
    @discardableResult
    public func addComponent(
        kind: String,
        name: String,
        iconSystemName: String,
        myAppId: UUID? = nil
    ) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let idx = myApps.firstIndex(where: { $0.id == target }) else { return nil }
        // Drop any empty placeholders. The default seed lives here until
        // the first real component is added; collapsing it keeps the
        // sidebar tidy and lets id allocation start cleanly at
        // `<kind>-1`.
        myApps[idx].components.removeAll {
            if case .empty = $0.body { return true }
            return false
        }
        let prefix = kind
        var n = 1
        let existing = Set(myApps[idx].components.map(\.id))
        while existing.contains("\(prefix)-\(n)") { n += 1 }
        let id = "\(prefix)-\(n)"
        let component = Component(
            id: id,
            name: name.isEmpty ? kind.capitalized : name,
            iconSystemName: iconSystemName,
            body: CanvasApp.emptyBody(forKind: kind)
        )
        myApps[idx].components.append(component)
        myApps[idx].activeComponentId = id
        persist()
        emitItemEvent(myAppId: target, componentId: id, kind: .added, actor: .user,
                      inverse: .componentAdded(componentId: id))
        return id
    }


    /// Remove a component from `myAppId`. Refuses if it would leave the
    /// MyApp with zero components — a MyApp must always have at least one
    /// child row in the sidebar.
    @discardableResult
    public func removeComponent(componentId: String, myAppId: UUID? = nil) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else { return false }
        guard myApps[mIdx].components.count > 1,
              let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == componentId })
        else { return false }
        let removedComponent = myApps[mIdx].components[cIdx]
        myApps[mIdx].components.remove(at: cIdx)
        if myApps[mIdx].activeComponentId == componentId {
            myApps[mIdx].activeComponentId = myApps[mIdx].components.first?.id
        }
        persist()
        emitItemEvent(myAppId: target, componentId: componentId, kind: .removed, actor: .user,
                      inverse: .componentRemoved(snapshot: removedComponent, index: cIdx))
        return true
    }

    /// Make `componentId` the active component of `myAppId`. The active
    /// component drives the canvas view and the `canvas` accessor on `MyApp`.
    @discardableResult
    public func setActiveComponent(componentId: String, myAppId: UUID? = nil) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }),
              myApps[mIdx].components.contains(where: { $0.id == componentId }) else { return false }
        myApps[mIdx].activeComponentId = componentId
        persist()
        return true
    }

    /// Rename a component (sidebar child row label). No effect on body.
    @discardableResult
    public func renameComponent(componentId: String, to newName: String, myAppId: UUID? = nil) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }),
              let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == componentId })
        else { return false }
        guard myApps[mIdx].components[cIdx].name != trimmed else { return false }
        myApps[mIdx].components[cIdx].name = trimmed
        persist()
        return true
    }

    /// Set or clear the LLM-authored content `summary` for a component
    /// (the slot surfaced in the canvas state context entry every turn).
    /// Targets a component by kind using the same selection rule as
    /// `mutate(_:kind:_:)`: prefers the active component if it matches
    /// the kind, else the first component of that kind. Passing `nil`
    /// (or an all-whitespace string) clears the existing summary.
    @discardableResult
    public func setComponentSummary(
        forKind kind: String,
        summary: String?,
        myAppId: UUID? = nil
    ) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else { return false }
        let m = myApps[mIdx]
        let activeIdx = m.activeComponentId.flatMap { id in
            m.components.firstIndex(where: { $0.id == id })
        }
        let cIdx: Int?
        if let active = activeIdx, m.components[active].kindString == kind {
            cIdx = active
        } else if let matching = m.components.firstIndex(where: { $0.kindString == kind }) {
            cIdx = matching
        } else {
            cIdx = nil
        }
        guard let cIdx else { return false }
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty == false) ? trimmed : nil
        guard myApps[mIdx].components[cIdx].summary != next else { return false }
        myApps[mIdx].components[cIdx].summary = next
        persist()
        return true
    }

    // MARK: - Canvas mutators
    //
    // Every tool handler registered via `AppTools.registerMyAppTools` closes
    // over a fixed `myAppId` at session-construction time and threads it
    // through these mutators, so concurrent streams in different myApps
    // never race on `activeMyAppId`. Callers that genuinely want "the
    // currently visible myApp" (e.g. UI affordances on the canvas) omit
    // `myAppId:` and fall back to `activeMyAppId` via the helper below.
    //
    // Tracker mutators route through `mutate(_, kind: "tracker", _)`; the
    // store finds the first tracker component in the MyApp (preferring the
    // active one if it's a tracker). Calendar mutators do the same with
    // `kind: "calendar"`. This keeps tools that operate on "the tracker" /
    // "the calendar" working symmetrically regardless of which component
    // the user is currently viewing.

    public func reset(myAppId: UUID? = nil) {
        mutate(myAppId, kind: nil) { canvas in
            if case .empty = canvas { return false }
            canvas = .empty
            return true
        }
    }

    public func setTracker(title: String, fields: [FieldDef], myAppId: UUID? = nil) {
        mutate(myAppId, kind: "tracker") { canvas in
            canvas = .tracker(TrackerData(title: title, fields: fields))
            return true
        }
    }

    /// Append a new item with a freshly-generated `id`. Returns the new id so
    /// the tool-call echo can surface it back to the agent (the agent then
    /// refers to the item by id on subsequent calls, which is stable across
    /// filter / reorder / hide-show shuffles in a way that array indices are
    /// not).
    @discardableResult
    public func addItem(
        _ values: [String: String],
        myAppId: UUID? = nil,
        actor: ItemEventActor = .user
    ) -> UUID? {
        let item = TrackerItem(id: UUID(), values: values)
        let compId = trackerComponentId(myAppId: myAppId)
        var added: UUID?
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { return false }
            t.items.append(item)
            canvas = .tracker(t)
            added = item.id
            return true
        }
        if added != nil, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .added, actor: actor,
                          itemId: item.id, inverse: .trackerAdded(itemId: item.id))
        }
        return added
    }

    @discardableResult
    public func removeItem(
        id: UUID,
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> Bool {
        // When a specific componentId is supplied, scope both the mutate
        // and the cascade to it; otherwise fall back to kind-preference.
        let resolvedCompId: String? = componentId ?? trackerComponentId(myAppId: myAppId)
        var ok = false
        var removedItem: TrackerItem?
        var removedIdx: Int?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.items.firstIndex(where: { $0.id == id }) else { return false }
            removedItem = t.items[idx]
            removedIdx = idx
            t.items.remove(at: idx)
            canvas = .tracker(t)
            ok = true
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "tracker", body)
        }
        // Drop any inbound refs to the removed item from every
        // link-bearing component in this MyApp, so calendar / checklist
        // pills don't dangle.
        if ok, let compId = resolvedCompId {
            cascadeRemoveRefs(
                toComponentId: compId,
                itemId: id,
                myAppId: myAppId
            )
            let inverse: ItemEventInverse? = removedItem.map {
                .trackerRemoved(snapshot: $0, index: removedIdx ?? 0)
            }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return ok
    }

    public func removeItem(at index: Int, myAppId: UUID? = nil, actor: ItemEventActor = .user) {
        let trackerComponentId = trackerComponentId(myAppId: myAppId)
        var removedItem: TrackerItem?
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas, t.items.indices.contains(index) else { return false }
            removedItem = t.items[index]
            t.items.remove(at: index)
            canvas = .tracker(t)
            return true
        }
        if let removedItem, let compId = trackerComponentId {
            cascadeRemoveRefs(
                toComponentId: compId,
                itemId: removedItem.id,
                myAppId: myAppId
            )
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: removedItem.id,
                          inverse: .trackerRemoved(snapshot: removedItem, index: index))
        }
    }

    @discardableResult
    public func patchItem(
        id: UUID,
        with patch: [String: String],
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> Bool {
        let resolvedCompId = componentId ?? trackerComponentId(myAppId: myAppId)
        var ok = false
        var prior: TrackerItem?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.items.firstIndex(where: { $0.id == id }) else { return false }
            prior = t.items[idx]
            for (k, v) in patch { t.items[idx].values[k] = v }
            canvas = .tracker(t)
            ok = true
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "tracker", body)
        }
        if ok, let compId = resolvedCompId {
            let inverse: ItemEventInverse? = prior.map { .trackerPatched(snapshot: $0) }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return ok
    }

    public func patchItem(at index: Int, with patch: [String: String], myAppId: UUID? = nil, actor: ItemEventActor = .user) {
        let compId = trackerComponentId(myAppId: myAppId)
        var prior: TrackerItem?
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas, t.items.indices.contains(index) else { return false }
            prior = t.items[index]
            for (k, v) in patch { t.items[index].values[k] = v }
            canvas = .tracker(t)
            return true
        }
        if let compId {
            let inverse: ItemEventInverse? = prior.map { .trackerPatched(snapshot: $0) }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: prior?.id, inverse: inverse)
        }
    }

    /// Replace a tracker item's `linkedItems` wholesale. Used by the
    /// tracker-row link sheet on save; the agent uses the generic
    /// `linkItem` / `unlinkItem` tools (or `patchTrackerItems` if a
    /// `linkedItems` field is added there later) instead.
    @discardableResult
    public func setTrackerItemLinkedItems(
        id: UUID,
        refs: [ComponentItemRef],
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> Bool {
        var ok = false
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.items.firstIndex(where: { $0.id == id }) else { return false }
            let original = t.items[idx].linkedItems
            t.items[idx].linkedItems = refs
            t.items[idx].deduplicateLinkedItems()
            guard t.items[idx].linkedItems != original else { return false }
            canvas = .tracker(t)
            ok = true
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "tracker", body)
        }
        return ok
    }

    public func setFilter(field: String, value: String, myAppId: UUID? = nil) {
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { return false }
            if value.isEmpty { t.filter.removeValue(forKey: field) } else { t.filter[field] = value }
            canvas = .tracker(t)
            return true
        }
    }

    @discardableResult
    public func addFieldOption(fieldName: String, option: String, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.fields.firstIndex(where: { $0.name == fieldName }),
                  t.fields[idx].type == .select else { return false }
            var opts = t.fields[idx].options ?? []
            if !opts.contains(option) { opts.append(option) }
            t.fields[idx].options = opts
            canvas = .tracker(t)
            ok = true
            return true
        }
        return ok
    }

    @discardableResult
    public func removeFieldOption(fieldName: String, option: String, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.fields.firstIndex(where: { $0.name == fieldName }),
                  let opts = t.fields[idx].options else { return false }
            t.fields[idx].options = opts.filter { $0 != option }
            canvas = .tracker(t)
            ok = true
            return true
        }
        return ok
    }

    // MARK: - Field-schema mutators
    //
    // These never touch `items` (or only re-key item entries on rename).
    // `addField` / `reorderFields` / `setFieldHidden` leave item data
    // entirely untouched — items are sparse dicts that tolerate any field
    // list. `renameField` is the one mutator that walks items, atomically
    // moving values[from] → values[to] so no item data is orphaned.

    /// Field-schema mutation failed because of one of these reasons. Tools
    /// surface this back to the agent in the echo so it can correct its call.
    public enum FieldMutationError: String, Error, Sendable {
        case notTracker
        case duplicateName
        case unknownField
        case unknownDestination
        case invalidOrder
    }

    @discardableResult
    public func addField(_ field: FieldDef, myAppId: UUID? = nil) -> FieldMutationError? {
        var err: FieldMutationError?
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { err = .notTracker; return false }
            guard !t.fields.contains(where: { $0.name == field.name }) else {
                err = .duplicateName
                return false
            }
            t.fields.append(field)
            canvas = .tracker(t)
            return true
        }
        return err
    }

    /// Result of a rename. `migratedItems` is the number of items whose value
    /// dict actually contained the old key (and was therefore re-keyed); the
    /// other items survive untouched because their dicts had no entry for the
    /// renamed field. `remappedFilter` / `remappedColumnField` say whether the
    /// rename cascaded into `TrackerData.filter` or `columnField`.
    public struct FieldRenameResult: Sendable {
        public var migratedItems: Int
        public var remappedFilter: Bool
        public var remappedColumnField: Bool
    }

    /// Atomically rename a field. Updates `FieldDef.name`, re-keys every
    /// item's value dict (`values[from]` → `values[to]`), remaps the matching
    /// `filter` entry if any, and remaps `columnField` if it pointed at the
    /// renamed field. Rejects if `to` already exists on another field, since
    /// that would silently merge item values.
    public func renameField(
        from oldName: String,
        to newName: String,
        myAppId: UUID? = nil
    ) -> Result<FieldRenameResult, FieldMutationError> {
        var outcome: Result<FieldRenameResult, FieldMutationError> = .failure(.notTracker)
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { outcome = .failure(.notTracker); return false }
            guard let idx = t.fields.firstIndex(where: { $0.name == oldName }) else {
                outcome = .failure(.unknownField)
                return false
            }
            guard newName == oldName || !t.fields.contains(where: { $0.name == newName }) else {
                outcome = .failure(.duplicateName)
                return false
            }
            if newName == oldName {
                outcome = .success(FieldRenameResult(
                    migratedItems: 0,
                    remappedFilter: false,
                    remappedColumnField: false
                ))
                return false
            }
            t.fields[idx].name = newName
            var migrated = 0
            for i in t.items.indices {
                if let value = t.items[i].values.removeValue(forKey: oldName) {
                    t.items[i].values[newName] = value
                    migrated += 1
                }
            }
            var remappedFilter = false
            if let filterValue = t.filter.removeValue(forKey: oldName) {
                t.filter[newName] = filterValue
                remappedFilter = true
            }
            var remappedColumnField = false
            if t.columnField == oldName {
                t.columnField = newName
                remappedColumnField = true
            }
            canvas = .tracker(t)
            outcome = .success(FieldRenameResult(
                migratedItems: migrated,
                remappedFilter: remappedFilter,
                remappedColumnField: remappedColumnField
            ))
            return true
        }
        return outcome
    }

    /// Reorder `fields` so they appear in the order given. `order` must be a
    /// permutation of the existing field names — any mismatch (length,
    /// duplicate, unknown name) rejects without mutating. Items are not
    /// touched.
    @discardableResult
    public func reorderFields(_ order: [String], myAppId: UUID? = nil) -> FieldMutationError? {
        var err: FieldMutationError?
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { err = .notTracker; return false }
            let existing = Set(t.fields.map(\.name))
            guard order.count == t.fields.count,
                  Set(order) == existing,
                  order.count == existing.count else {
                err = .invalidOrder
                return false
            }
            let byName = Dictionary(uniqueKeysWithValues: t.fields.map { ($0.name, $0) })
            t.fields = order.compactMap { byName[$0] }
            canvas = .tracker(t)
            return true
        }
        return err
    }

    /// Result of toggling field visibility. `droppedFilterValue` is the
    /// previous filter value if the field had an active filter that was
    /// cleared on hide (otherwise nil — a hidden filter would silently keep
    /// hiding items from the visible view, which is confusing).
    public struct FieldHideResult: Sendable {
        public var hidden: Bool
        public var droppedFilterValue: String?
    }

    @discardableResult
    public func setFieldHidden(
        name: String,
        hidden: Bool,
        myAppId: UUID? = nil
    ) -> Result<FieldHideResult, FieldMutationError> {
        var outcome: Result<FieldHideResult, FieldMutationError> = .failure(.notTracker)
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { outcome = .failure(.notTracker); return false }
            guard let idx = t.fields.firstIndex(where: { $0.name == name }) else {
                outcome = .failure(.unknownField)
                return false
            }
            let currentlyHidden = t.fields[idx].hidden ?? false
            if currentlyHidden == hidden {
                outcome = .success(FieldHideResult(hidden: hidden, droppedFilterValue: nil))
                return false
            }
            t.fields[idx].hidden = hidden ? true : nil
            var droppedFilter: String?
            if hidden, let value = t.filter.removeValue(forKey: name) {
                droppedFilter = value
            }
            canvas = .tracker(t)
            outcome = .success(FieldHideResult(hidden: hidden, droppedFilterValue: droppedFilter))
            return true
        }
        return outcome
    }

    /// Switch the active tracker between grid and kanban rendering. Same
    /// `TrackerData` underneath — only `viewMode` (and `columnField` when
    /// entering kanban) changes. Returns the resolved `(mode, columnField)`
    /// so the tool-call echo can show the agent what was actually applied.
    ///
    /// Behaviour:
    /// - Non-tracker canvas → no-op, returns `nil`.
    /// - `.kanban`: if `columnField` is explicitly passed and refers to a
    ///   select field, use it; otherwise keep the existing `columnField` when
    ///   still valid; otherwise auto-pick the first select field with at
    ///   least one option. `columnField` may resolve to `nil` if no select
    ///   field exists — the kanban view then renders an empty-state hint.
    /// - `.grid`: just flips the mode, leaving `columnField` intact so a
    ///   later toggle restores the user's column choice.
    @discardableResult
    public func setTrackerViewMode(
        _ mode: TrackerViewMode,
        columnField: String? = nil,
        myAppId: UUID? = nil
    ) -> (mode: TrackerViewMode, columnField: String?)? {
        var result: (TrackerViewMode, String?)?
        mutate(myAppId, kind: "tracker") { canvas in
            guard case .tracker(var t) = canvas else { return false }
            let originalMode = t.viewMode
            let originalColumn = t.columnField
            let resolved: String?
            switch mode {
            case .kanban:
                if let requested = columnField,
                   t.fields.contains(where: {
                       $0.name == requested && $0.type == .select && !($0.hidden ?? false)
                   }) {
                    resolved = requested
                } else if let existing = t.columnField,
                          t.fields.contains(where: {
                              $0.name == existing && $0.type == .select && !($0.hidden ?? false)
                          }) {
                    resolved = existing
                } else {
                    resolved = t.fields.first(where: {
                        $0.type == .select && !($0.options ?? []).isEmpty && !($0.hidden ?? false)
                    })?.name
                }
            case .grid:
                resolved = t.columnField
            }
            t.viewMode = mode
            t.columnField = resolved
            result = (mode, resolved)
            let changed = (originalMode != mode) || (originalColumn != resolved)
            canvas = .tracker(t)
            return changed
        }
        return result
    }

    // MARK: - Calendar mutators

    /// Replace the calendar body of the first calendar component in
    /// `myAppId` (preferring the active component when it's a calendar).
    /// Destructive — wipes any existing events.
    public func setCalendar(title: String, events: [CalendarEvent] = [], myAppId: UUID? = nil) {
        mutate(myAppId, kind: "calendar") { canvas in
            canvas = .calendar(CalendarData(title: title, events: events))
            return true
        }
    }

    @discardableResult
    public func addCalendarEvent(_ event: CalendarEvent, myAppId: UUID? = nil, actor: ItemEventActor = .user) -> UUID? {
        let compId = calendarComponentId(myAppId: myAppId)
        var added: UUID?
        mutate(myAppId, kind: "calendar") { canvas in
            guard case .calendar(var c) = canvas else { return false }
            c.events.append(event)
            canvas = .calendar(c)
            added = event.id
            return true
        }
        if added != nil, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .added, actor: actor,
                          itemId: event.id, inverse: .calendarAdded(itemId: event.id))
        }
        return added
    }

    @discardableResult
    public func removeCalendarEvent(
        id: UUID,
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> CalendarEvent? {
        let resolvedCompId: String? = componentId ?? calendarComponentId(myAppId: myAppId)
        var removed: CalendarEvent?
        var removedIdx: Int?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calendar(var c) = canvas,
                  let idx = c.events.firstIndex(where: { $0.id == id }) else { return false }
            removedIdx = idx
            removed = c.events.remove(at: idx)
            canvas = .calendar(c)
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "calendar", body)
        }
        if removed != nil, let compId = resolvedCompId {
            cascadeRemoveRefs(
                toComponentId: compId,
                itemId: id,
                myAppId: myAppId
            )
            let inverse: ItemEventInverse? = removed.map {
                .calendarRemoved(snapshot: $0, index: removedIdx ?? 0)
            }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return removed
    }

    /// Switch the active calendar between list and month rendering.
    /// Returns the resolved mode so the tool-call echo can show what was
    /// applied. Non-calendar canvas → no-op, returns `nil`.
    @discardableResult
    public func setCalendarViewMode(_ mode: CalendarViewMode, myAppId: UUID? = nil) -> CalendarViewMode? {
        var result: CalendarViewMode?
        mutate(myAppId, kind: "calendar") { canvas in
            guard case .calendar(var c) = canvas else { return false }
            let changed = c.viewMode != mode
            c.viewMode = mode
            canvas = .calendar(c)
            result = mode
            return changed
        }
        return result
    }

    public struct CalendarEventPatch: Sendable {
        public var title: String?
        public var start: String?
        public var end: String??     // double-optional: nil = unchanged, .some(nil) = clear
        public var location: String??
        public var notes: String??
        public var linkedItems: [ComponentItemRef]?
    }

    @discardableResult
    public func patchCalendarEvent(
        id: UUID,
        patch: CalendarEventPatch,
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> CalendarEvent? {
        let resolvedCompId = componentId ?? calendarComponentId(myAppId: myAppId)
        var before: CalendarEvent?
        var after: CalendarEvent?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calendar(var c) = canvas,
                  let idx = c.events.firstIndex(where: { $0.id == id }) else { return false }
            before = c.events[idx]
            if let v = patch.title { c.events[idx].title = v }
            if let v = patch.start { c.events[idx].start = v }
            if let v = patch.end { c.events[idx].end = v }
            if let v = patch.location { c.events[idx].location = v }
            if let v = patch.notes { c.events[idx].notes = v }
            if let v = patch.linkedItems {
                c.events[idx].linkedItems = v
                c.events[idx].deduplicateLinkedItems()
            }
            after = c.events[idx]
            canvas = .calendar(c)
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "calendar", body)
        }
        if after != nil, let compId = resolvedCompId {
            let inverse: ItemEventInverse? = before.map { .calendarPatched(snapshot: $0) }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return after
    }

    // MARK: - Calendar ⇄ tracker linking

    /// Display name for a tracker item, used by the calendar's linked-item
    /// pills. Picks the first non-empty value from `displayField` (if the
    /// caller hinted one), else the first visible text field, else falls
    /// back to a short id stub. Trailing whitespace stripped.
    public func displayNameForTrackerItem(
        componentId: String,
        itemId: UUID,
        myAppId: UUID? = nil
    ) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .tracker(let t) = comp.body,
              let item = t.items.first(where: { $0.id == itemId }) else { return nil }
        // First visible text field with a non-empty value.
        for field in t.visibleFields where field.type == .text {
            if let v = item.values[field.name]?.nonEmpty { return v }
        }
        // Anything visible with a value, as a fallback.
        for field in t.visibleFields {
            if let v = item.values[field.name]?.nonEmpty { return v }
        }
        return nil
    }

    /// Tracker component's sidebar-visible name (`comp.name`) for a given
    /// ref. Used in linked-item pill tooltips / picker rows.
    public func componentName(_ componentId: String, myAppId: UUID? = nil) -> String? {
        let target = myAppId ?? activeMyAppId
        return myApps.first(where: { $0.id == target })?
            .components.first(where: { $0.id == componentId })?.name
    }

    /// Attach a tracker item to a calendar event. No-op if the ref is
    /// already in the event's `linkedItems`, the event doesn't exist, or
    /// the calendar component is missing. Returns the updated link count
    /// on success.
    /// Replace a calendar event's `linkedItems` wholesale. Used by
    /// `patchCalendarEvent` when the agent supplies a `linkedItems`
    /// patch.
    @discardableResult
    public func setCalendarEventLinkedItems(
        eventId: UUID,
        refs: [ComponentItemRef],
        myAppId: UUID? = nil
    ) -> Bool {
        var ok = false
        mutate(myAppId, kind: "calendar") { canvas in
            guard case .calendar(var cal) = canvas,
                  let idx = cal.events.firstIndex(where: { $0.id == eventId }) else { return false }
            // De-duplicate while preserving order so the agent can send
            // a list with accidental repeats and still get a sane result.
            var seen = Set<ComponentItemRef>()
            let deduped = refs.filter { seen.insert($0).inserted }
            guard cal.events[idx].linkedItems != deduped else { return false }
            cal.events[idx].linkedItems = deduped
            canvas = .calendar(cal)
            ok = true
            return true
        }
        return ok
    }

    /// Internal: id of the first tracker component in `myAppId` (or
    /// active component if it's a tracker). Used by the item-delete
    /// sweep to figure out which `componentId` to scan calendar links
    /// against.
    private func trackerComponentId(myAppId: UUID?) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .tracker = comp.body { return comp.id }
        return myApp.components.first(where: {
            if case .tracker = $0.body { return true }
            return false
        })?.id
    }

    /// Internal: id of the first calendar component in `myAppId` (or
    /// active component if it's a calendar). Used by the event-delete
    /// sweep to figure out which `componentId` to scan inbound refs
    /// against.
    private func calendarComponentId(myAppId: UUID?) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .calendar = comp.body { return comp.id }
        return myApp.components.first(where: {
            if case .calendar = $0.body { return true }
            return false
        })?.id
    }

    /// Walk every link-bearing component in `myAppId` and drop refs
    /// pointing at `(componentId, itemId)`. Called after a tracker item,
    /// calendar event, or checklist item is removed so the inline pills
    /// rendered by other components don't dangle. Source items keep their
    /// own title / text / start / notes — only the matching pill
    /// disappears. As of project `0.0.41`, every kind that can hold
    /// `linkedItems` (tracker rows + calendar events + checklist rows)
    /// is swept here, so a removed item drops both inbound refs from
    /// other components AND inbound refs from rows in the same kind
    /// (e.g. tracker row → tracker row in the same tracker).
    private func cascadeRemoveRefs(
        toComponentId componentId: String,
        itemId: UUID,
        myAppId: UUID?
    ) {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else { return }
        var dirty = false
        for cIdx in myApps[mIdx].components.indices {
            let before = myApps[mIdx].components[cIdx].body
            myApps[mIdx].components[cIdx].body.mapLinkedItems { refs in
                refs.removeAll(where: { $0.componentId == componentId && $0.itemId == itemId })
            }
            if myApps[mIdx].components[cIdx].body != before { dirty = true }
        }
        if dirty { persist() }
    }

    // MARK: - Checklist mutators

    /// Replace the checklist body of the first checklist component in
    /// `myAppId` (preferring the active component when it's a checklist).
    /// Destructive — wipes any existing items.
    public func setChecklist(title: String, items: [ChecklistItem] = [], myAppId: UUID? = nil) {
        mutate(myAppId, kind: "checklist") { canvas in
            canvas = .checklist(ChecklistData(title: title, items: items))
            return true
        }
    }

    /// Append a new checklist item. Returns its stable id so the tool
    /// echo can hand it back to the agent.
    @discardableResult
    public func addChecklistItem(
        text: String,
        done: Bool = false,
        myAppId: UUID? = nil,
        actor: ItemEventActor = .user
    ) -> UUID? {
        let compId = checklistComponentId(myAppId: myAppId)
        let item = ChecklistItem(text: text, done: done)
        var added: UUID?
        mutate(myAppId, kind: "checklist") { canvas in
            guard case .checklist(var cl) = canvas else { return false }
            cl.items.append(item)
            canvas = .checklist(cl)
            added = item.id
            return true
        }
        if added != nil, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .added, actor: actor,
                          itemId: item.id, inverse: .checklistAdded(itemId: item.id))
        }
        return added
    }

    /// Flip the `done` flag of a checklist item. Returns the new value,
    /// or nil if the item isn't found.
    @discardableResult
    public func toggleChecklistItem(id: UUID, myAppId: UUID? = nil, actor: ItemEventActor = .user) -> Bool? {
        let compId = checklistComponentId(myAppId: myAppId)
        var prior: ChecklistItem?
        var newValue: Bool?
        mutate(myAppId, kind: "checklist") { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }) else { return false }
            prior = cl.items[idx]
            cl.items[idx].done.toggle()
            newValue = cl.items[idx].done
            canvas = .checklist(cl)
            return true
        }
        if newValue != nil, let compId {
            let inverse: ItemEventInverse? = prior.map { .checklistPatched(snapshot: $0) }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return newValue
    }

    /// Set the `done` flag explicitly. Used by the SwiftUI checkbox
    /// binding so a tap idempotently sets the target state rather than
    /// toggling (avoids races between the binding read and the write).
    @discardableResult
    public func setChecklistItemDone(id: UUID, done: Bool, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "checklist") { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }),
                  cl.items[idx].done != done else { return false }
            cl.items[idx].done = done
            canvas = .checklist(cl)
            ok = true
            return true
        }
        return ok
    }

    public struct ChecklistItemPatch: Sendable {
        public var text: String?
        public var done: Bool?
        public var linkedItems: [ComponentItemRef]?

        public init(
            text: String? = nil,
            done: Bool? = nil,
            linkedItems: [ComponentItemRef]? = nil
        ) {
            self.text = text
            self.done = done
            self.linkedItems = linkedItems
        }
    }

    @discardableResult
    public func patchChecklistItem(
        id: UUID,
        patch: ChecklistItemPatch,
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> ChecklistItem? {
        let resolvedCompId = componentId ?? checklistComponentId(myAppId: myAppId)
        var before: ChecklistItem?
        var after: ChecklistItem?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }) else { return false }
            before = cl.items[idx]
            if let v = patch.text { cl.items[idx].text = v }
            if let v = patch.done { cl.items[idx].done = v }
            if let v = patch.linkedItems {
                cl.items[idx].linkedItems = v
                cl.items[idx].deduplicateLinkedItems()
            }
            after = cl.items[idx]
            canvas = .checklist(cl)
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "checklist", body)
        }
        if after != nil, let compId = resolvedCompId {
            let inverse: ItemEventInverse? = before.map { .checklistPatched(snapshot: $0) }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return after
    }

    @discardableResult
    public func removeChecklistItem(
        id: UUID,
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> ChecklistItem? {
        let resolvedCompId: String? = componentId ?? checklistComponentId(myAppId: myAppId)
        var removed: ChecklistItem?
        var removedIdx: Int?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }) else { return false }
            removedIdx = idx
            removed = cl.items.remove(at: idx)
            canvas = .checklist(cl)
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "checklist", body)
        }
        if removed != nil, let compId = resolvedCompId {
            cascadeRemoveRefs(toComponentId: compId, itemId: id, myAppId: myAppId)
            let inverse: ItemEventInverse? = removed.map {
                .checklistRemoved(snapshot: $0, index: removedIdx ?? 0)
            }
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: id, inverse: inverse)
        }
        return removed
    }

    /// Internal: id of the first checklist component in `myAppId` (or
    /// active component if it's a checklist). Mirrors the calendar /
    /// tracker helpers.
    private func checklistComponentId(myAppId: UUID?) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .checklist = comp.body { return comp.id }
        return myApp.components.first(where: {
            if case .checklist = $0.body { return true }
            return false
        })?.id
    }

    // MARK: - Calculator mutators
    //
    // Mirror the checklist mutators: kind-routed via `mutate(_:kind:"calculator")`
    // (or `byComponentId` for a targeted call), `@discardableResult`, persist
    // only on change. Calc-row edits emit an `ItemEvent` for the History
    // sheet but carry no inverse — calculator rows aren't in the undo graph
    // yet (Phase 1), so they show as non-reversible entries. The UI tuning
    // path (`setCalculatorVariable`) deliberately emits NO event: a slider
    // drag would otherwise flood the log, exactly as `setChecklistItemDone`
    // stays silent next to `toggleChecklistItem`.

    /// Replace the calculator body of the first calculator component in
    /// `myAppId` (preferring the active component when it's a calculator).
    /// Destructive — wipes any existing rows.
    public func setCalculator(title: String, rows: [CalcRow] = [], myAppId: UUID? = nil) {
        mutate(myAppId, kind: "calculator") { canvas in
            canvas = .calculator(CalculatorData(title: title, rows: rows))
            return true
        }
    }

    /// Patch payload for `patchCalcRow`. Double-optional `unit` / `format`
    /// distinguish "unchanged" (nil) from "clear" (`.some(nil)`). `kind`
    /// replaces the whole row kind (variable ⇄ aggregate ⇄ formula).
    public struct CalcRowPatch: Sendable {
        public var name: String?
        public var unit: String??
        public var format: String??
        public var kind: CalcRowKind?

        public init(
            name: String? = nil,
            unit: String?? = nil,
            format: String?? = nil,
            kind: CalcRowKind? = nil
        ) {
            self.name = name
            self.unit = unit
            self.format = format
            self.kind = kind
        }
    }

    /// Append a calc row. The stable `key` formulas reference is slugified
    /// from `key` (or `name` when `key` is omitted) and de-duplicated
    /// against existing keys (`spend`, `spend_2`, …) so it's always a unique
    /// identifier. Returns the resolved key, or nil if there's no calculator
    /// component in this MyApp.
    @discardableResult
    public func addCalcRow(
        key: String? = nil,
        name: String,
        unit: String? = nil,
        format: String? = nil,
        kind: CalcRowKind,
        myAppId: UUID? = nil,
        actor: ItemEventActor = .user
    ) -> String? {
        let compId = calculatorComponentId(myAppId: myAppId)
        var resolvedKey: String?
        var rowId: UUID?
        mutate(myAppId, kind: "calculator") { canvas in
            guard case .calculator(var c) = canvas else { return false }
            let base = Self.slugify(key?.nonEmpty ?? name)
            let unique = Self.dedupeSlug(base, existing: Set(c.rows.map(\.key)))
            let row = CalcRow(
                key: unique,
                name: name.nonEmpty ?? unique,
                unit: unit,
                format: format,
                kind: kind
            )
            c.rows.append(row)
            canvas = .calculator(c)
            resolvedKey = unique
            rowId = row.id
            return true
        }
        if let resolvedKey, let compId, let rowId {
            _ = resolvedKey
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .added, actor: actor, itemId: rowId)
        }
        return resolvedKey
    }

    /// Remove a calc row by its stable `key`. Returns true if a row was
    /// removed. Note: existing formulas that referenced the removed key
    /// then resolve to `brokenRef` — handled live by `CalculatorResolver`,
    /// not by rewriting other rows here.
    @discardableResult
    public func removeCalcRow(key: String, myAppId: UUID? = nil, actor: ItemEventActor = .user) -> Bool {
        let compId = calculatorComponentId(myAppId: myAppId)
        var removedId: UUID?
        mutate(myAppId, kind: "calculator") { canvas in
            guard case .calculator(var c) = canvas,
                  let idx = c.rows.firstIndex(where: { $0.key == key }) else { return false }
            removedId = c.rows[idx].id
            c.rows.remove(at: idx)
            canvas = .calculator(c)
            return true
        }
        if let removedId, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor, itemId: removedId)
        }
        return removedId != nil
    }

    /// Edit a calc row by `key`. Only fields present in `patch` change;
    /// the `key` itself is immutable so formulas never break under a patch.
    @discardableResult
    public func patchCalcRow(
        key: String,
        patch: CalcRowPatch,
        myAppId: UUID? = nil,
        actor: ItemEventActor = .user
    ) -> Bool {
        let compId = calculatorComponentId(myAppId: myAppId)
        var patchedId: UUID?
        mutate(myAppId, kind: "calculator") { canvas in
            guard case .calculator(var c) = canvas,
                  let idx = c.rows.firstIndex(where: { $0.key == key }) else { return false }
            if let v = patch.name { c.rows[idx].name = v }
            if let v = patch.unit { c.rows[idx].unit = v }
            if let v = patch.format { c.rows[idx].format = v }
            if let v = patch.kind { c.rows[idx].kind = v }
            patchedId = c.rows[idx].id
            canvas = .calculator(c)
            return true
        }
        if let patchedId, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor, itemId: patchedId)
        }
        return patchedId != nil
    }

    /// Set a `variable` row's value from the UI tuning control (slider /
    /// stepper / field). No-op (and no event) if the row isn't a variable
    /// or the value is unchanged — keeps live slider drags off the History
    /// log and out of `persist()` churn when nothing moved.
    @discardableResult
    public func setCalculatorVariable(
        key: String,
        value: Double,
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> Bool {
        var ok = false
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calculator(var c) = canvas,
                  let idx = c.rows.firstIndex(where: { $0.key == key }),
                  case .variable(let current, let control) = c.rows[idx].kind,
                  current != value else { return false }
            c.rows[idx].kind = .variable(value: value, control: control)
            canvas = .calculator(c)
            ok = true
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "calculator", body)
        }
        return ok
    }

    /// Internal: id of the first calculator component in `myAppId` (or the
    /// active component if it's a calculator). Mirrors the tracker /
    /// calendar / checklist helpers; used by the calculator tools when no
    /// explicit `componentId` is passed.
    public func calculatorComponentId(myAppId: UUID? = nil) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .calculator = comp.body { return comp.id }
        return myApp.components.first(where: {
            if case .calculator = $0.body { return true }
            return false
        })?.id
    }

    // MARK: - Chart mutators
    //
    // Mirror the calculator mutators: kind-routed via `mutate(_:kind:"chart")`,
    // `@discardableResult`, persist only on change. A chart is non-linkable
    // and single-spec (title + kind + source), so there's no per-item event —
    // a render / patch is a single component-level edit.

    /// Patch payload for `patchChart`. Each field nil = unchanged. `series`
    /// replaces the whole series list.
    public struct ChartPatch: Sendable {
        public var title: String?
        public var kind: ChartKind?
        public var series: [ChartSeriesSpec]?

        public init(title: String? = nil, kind: ChartKind? = nil, series: [ChartSeriesSpec]? = nil) {
            self.title = title
            self.kind = kind
            self.series = series
        }
    }

    /// Replace the chart body of the first chart component in `myAppId`
    /// (preferring the active component when it's a chart). Destructive —
    /// overwrites title / kind / series.
    public func setChart(title: String, kind: ChartKind, series: [ChartSeriesSpec], myAppId: UUID? = nil) {
        mutate(myAppId, kind: "chart") { canvas in
            canvas = .chart(ChartData(title: title, kind: kind, series: series))
            return true
        }
    }

    /// Patch a chart in place — only fields present in `patch` change.
    /// Returns true if a chart component was found and edited.
    @discardableResult
    public func patchChart(patch: ChartPatch, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "chart") { canvas in
            guard case .chart(var c) = canvas else { return false }
            if let v = patch.title { c.title = v }
            if let v = patch.kind { c.kind = v }
            if let v = patch.series { c.series = v }
            canvas = .chart(c)
            ok = true
            return true
        }
        return ok
    }

    /// Append series specs to the chart. Returns the new series count, or nil
    /// if no chart component exists.
    @discardableResult
    public func addChartSeries(_ specs: [ChartSeriesSpec], myAppId: UUID? = nil) -> Int? {
        var count: Int?
        mutate(myAppId, kind: "chart") { canvas in
            guard case .chart(var c) = canvas, !specs.isEmpty else { return false }
            c.series.append(contentsOf: specs)
            canvas = .chart(c)
            count = c.series.count
            return true
        }
        return count
    }

    /// Remove the series at `index` (0-based). Returns true on removal.
    @discardableResult
    public func removeChartSeries(index: Int, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "chart") { canvas in
            guard case .chart(var c) = canvas, c.series.indices.contains(index) else { return false }
            c.series.remove(at: index)
            canvas = .chart(c)
            ok = true
            return true
        }
        return ok
    }

    /// Set just a chart's `kind` (pie ⇄ bar ⇄ line). Returns true on change.
    @discardableResult
    public func setChartKind(_ kind: ChartKind, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "chart") { canvas in
            guard case .chart(var c) = canvas, c.kind != kind else { return false }
            c.kind = kind
            canvas = .chart(c)
            ok = true
            return true
        }
        return ok
    }

    /// Id of the first chart component in `myAppId` (or the active component
    /// if it's a chart). Mirrors `calculatorComponentId`.
    public func chartComponentId(myAppId: UUID? = nil) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .chart = comp.body { return comp.id }
        return myApp.components.first(where: {
            if case .chart = $0.body { return true }
            return false
        })?.id
    }

    /// Set (or clear, with `nil`) the chart embedded inside the first
    /// calculator component in `myAppId`. Returns true on change — lets a
    /// chart live inside a calculator without a separate chart component.
    @discardableResult
    public func setCalculatorInlineChart(_ chart: ChartData?, myAppId: UUID? = nil) -> Bool {
        var ok = false
        mutate(myAppId, kind: "calculator") { canvas in
            guard case .calculator(var c) = canvas, c.inlineChart != chart else { return false }
            c.inlineChart = chart
            canvas = .calculator(c)
            ok = true
            return true
        }
        return ok
    }

    /// Slugify `s` into a valid expression identifier (lowercase, words
    /// joined by `_`, leading digits kept but the result is never empty).
    /// Calc-row keys must be valid `ExpressionEngine` identifiers because
    /// formulas reference them by name. `nonisolated` so the tool layer can
    /// dedupe keys off the MainActor while parsing tool args.
    nonisolated static func slugify(_ s: String) -> String {
        var out = ""
        var pendingUnderscore = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingUnderscore, !out.isEmpty { out.append("_") }
                pendingUnderscore = false
                out.append(ch)
            } else {
                pendingUnderscore = true
            }
        }
        // A pure-digit slug ("2024") is a valid key but not a valid
        // identifier; prefix it so formulas can reference it.
        if let first = out.first, first.isNumber { out = "v_" + out }
        return out.isEmpty ? "row" : out
    }

    /// Append `_2`, `_3`, … to `base` until it's unique among `existing`.
    nonisolated static func dedupeSlug(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
    }

    // MARK: - Slack mutators

    /// Append a `SlackAgent` to the Slack body. Returns the generated
    /// stable id (used as the per-agent memory namespace). `componentId`
    /// targets a specific component; nil resolves to the active /
    /// first-found Slack component.
    @discardableResult
    public func slackAddAgent(
        name: String,
        role: String,
        systemPromptAddition: String,
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var newId: String?
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas else { return false }
            let id = Self.nextSlackId(prefix: "agent", existing: s.agents.map(\.id))
            s.agents.append(SlackAgent(
                id: id,
                name: trimmed,
                role: role,
                systemPromptAddition: systemPromptAddition
            ))
            canvas = .slack(s)
            newId = id
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, mutator)
        } else {
            mutate(myAppId, kind: "slack", mutator)
        }
        return newId
    }

    /// Append a `SlackChannel` to the Slack body. Returns the generated
    /// stable id. `memberAgentIds` are validated against the component's
    /// known agents — unknown ids are dropped silently rather than
    /// failing the whole call.
    @discardableResult
    public func slackAddChannel(
        name: String,
        type: SlackChannelType,
        memberAgentIds: [String] = [],
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var newId: String?
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas else { return false }
            let known = Set(s.agents.map(\.id))
            let id = Self.nextSlackId(prefix: "channel", existing: s.channels.map(\.id))
            s.channels.append(SlackChannel(
                id: id,
                name: trimmed,
                type: type,
                memberAgentIds: memberAgentIds.filter(known.contains)
            ))
            if s.activeChannelId == nil {
                s.activeChannelId = id
            }
            canvas = .slack(s)
            newId = id
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, mutator)
        } else {
            mutate(myAppId, kind: "slack", mutator)
        }
        return newId
    }

    /// Add agents to a channel's member roster. Idempotent — already-
    /// present ids are skipped. Returns true if at least one new id was
    /// appended.
    @discardableResult
    public func slackAddAgentsToChannel(
        channelId: String,
        agentIds: [String],
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> Bool {
        var changed = false
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas,
                  let cIdx = s.channels.firstIndex(where: { $0.id == channelId }) else { return false }
            let known = Set(s.agents.map(\.id))
            var existing = Set(s.channels[cIdx].memberAgentIds)
            var localChanged = false
            for id in agentIds where known.contains(id) && existing.insert(id).inserted {
                s.channels[cIdx].memberAgentIds.append(id)
                localChanged = true
            }
            if localChanged {
                canvas = .slack(s)
                changed = true
            }
            return localChanged
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, mutator)
        } else {
            mutate(myAppId, kind: "slack", mutator)
        }
        return changed
    }

    /// Set which channel the user is currently viewing. No-op if the
    /// channel doesn't exist.
    @discardableResult
    public func slackSetActiveChannel(
        channelId: String,
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> Bool {
        var changed = false
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas,
                  s.channels.contains(where: { $0.id == channelId }) else { return false }
            if s.activeChannelId != channelId {
                s.activeChannelId = channelId
                canvas = .slack(s)
                changed = true
                return true
            }
            return false
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, mutator)
        } else {
            mutate(myAppId, kind: "slack", mutator)
        }
        return changed
    }

    /// Append a message to a channel. `authorKind = .user` uses
    /// `"user"` as the conventional authorId; `.agent` expects an
    /// existing `SlackAgent.id`. Returns the generated message id, or
    /// nil if the channel doesn't exist.
    @discardableResult
    public func slackPostMessage(
        channelId: String,
        authorKind: SlackAuthorKind,
        authorId: String,
        text: String,
        mentionedAgentIds: [String] = [],
        timestamp: Date = Date(),
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var newId: String?
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas,
                  s.channels.contains(where: { $0.id == channelId }) else { return false }
            let id = UUID().uuidString
            let msg = SlackMessage(
                id: id,
                channelId: channelId,
                authorKind: authorKind,
                authorId: authorId,
                text: trimmed,
                timestamp: timestamp,
                mentionedAgentIds: mentionedAgentIds
            )
            s.messagesByChannel[channelId, default: []].append(msg)
            canvas = .slack(s)
            newId = id
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, mutator)
        } else {
            mutate(myAppId, kind: "slack", mutator)
        }
        return newId
    }

    /// Find-or-create a 1-on-1 DM channel with `agentId`. A DM is the
    /// unique channel whose `type == .dm` and `memberAgentIds == [agentId]`
    /// — when the user clicks an agent in the sidebar we either jump to
    /// that channel or create it on the spot, named after the agent.
    /// Returns the channel id, or nil if `agentId` doesn't exist on this
    /// Slack component.
    @discardableResult
    public func slackOpenDM(
        agentId: String,
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> String? {
        var resolvedId: String?
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas,
                  let agent = s.agents.first(where: { $0.id == agentId }) else { return false }
            if let existing = s.channels.first(where: {
                $0.type == .dm && $0.memberAgentIds == [agentId]
            }) {
                resolvedId = existing.id
                return false
            }
            let id = Self.nextSlackId(prefix: "channel", existing: s.channels.map(\.id))
            s.channels.append(SlackChannel(
                id: id,
                name: agent.name,
                type: .dm,
                memberAgentIds: [agentId]
            ))
            canvas = .slack(s)
            resolvedId = id
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, mutator)
        } else {
            mutate(myAppId, kind: "slack", mutator)
        }
        return resolvedId
    }

    /// Resolve the active / first-found Slack component id for `myAppId`.
    /// Mirrors `trackerComponentId` etc. and is what the (forthcoming)
    /// Slack tools use when an explicit `componentId` isn't passed.
    public func slackComponentId(myAppId: UUID? = nil) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .slack = comp.body { return comp.id }
        return myApp.components.first(where: {
            if case .slack = $0.body { return true }
            return false
        })?.id
    }

    /// Allocate the next `<prefix>-N` id not already in `existing`.
    /// Mirrors the convention used by `addComponent` for the per-kind
    /// `tracker-N`, `calendar-N`, `checklist-N` id scheme.
    private static func nextSlackId(prefix: String, existing: [String]) -> String {
        let set = Set(existing)
        var n = 1
        while set.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    // MARK: - Universal item-to-item linking

    /// Result of `linkItems` / `unlinkItems`. Distinguishes "ref already
    /// present" / "ref absent" no-ops from "source / target doesn't
    /// exist" / "true self-reference" errors so the tool echo can show
    /// the agent why nothing changed.
    public enum LinkMutationError: String, Error, Sendable {
        /// `sourceComponentId` resolves to no component, or the
        /// component isn't link-bearing (`.empty`).
        case unknownSource
        /// `sourceItemId` doesn't match any item in the resolved source
        /// component.
        case unknownSourceItem
        /// `targetComponentId` resolves to no component.
        case unknownTarget
        /// `targetItemId` doesn't match any item in the resolved target
        /// component.
        case unknownTargetItem
        /// Source and target are the same `(componentId, itemId)`. A
        /// row linking to itself adds no information; rejected. Other
        /// self-component links (different row in the same component)
        /// are allowed.
        case selfReference
    }

    /// Attach a ref from one item (`sourceComponentId`, `sourceItemId`)
    /// to another (`targetComponentId`, `targetItemId`). Source and
    /// target may belong to the same component (e.g. tracker row →
    /// another tracker row for parent / dependency relationships) — only
    /// a literal self-ref where source and target are the same id is
    /// rejected. Idempotent: a ref that's already in `linkedItems`
    /// no-ops and reports the unchanged count. Returns the updated link
    /// count, or a `LinkMutationError` describing why nothing changed.
    @discardableResult
    public func linkItems(
        sourceComponentId: String,
        sourceItemId: UUID,
        targetComponentId: String,
        targetItemId: UUID,
        myAppId: UUID? = nil
    ) -> Result<Int, LinkMutationError> {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else {
            return .failure(.unknownSource)
        }
        // True self-ref check first — no point hitting the store if the
        // call is nonsensical.
        if sourceComponentId == targetComponentId, sourceItemId == targetItemId {
            return .failure(.selfReference)
        }
        // Target must exist before we mutate the source — keeps
        // `linkedItems` arrays clean of refs the resolver can't render.
        guard let targetComp = myApps[mIdx].components.first(where: { $0.id == targetComponentId }) else {
            return .failure(.unknownTarget)
        }
        guard itemExists(in: targetComp, itemId: targetItemId) else {
            return .failure(.unknownTargetItem)
        }
        // Source component lookup + targeted mutation.
        guard let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == sourceComponentId }) else {
            return .failure(.unknownSource)
        }
        let ref = ComponentItemRef(componentId: targetComponentId, itemId: targetItemId)
        var result: Result<Int, LinkMutationError> = .failure(.unknownSourceItem)
        var bodyVal = myApps[mIdx].components[cIdx].body
        switch bodyVal {
        case .tracker(var t):
            guard let iIdx = t.items.firstIndex(where: { $0.id == sourceItemId }) else {
                return .failure(.unknownSourceItem)
            }
            if t.items[iIdx].linkedItems.contains(ref) {
                result = .success(t.items[iIdx].linkedItems.count)
                return result
            }
            t.items[iIdx].linkedItems.append(ref)
            bodyVal = .tracker(t)
            result = .success(t.items[iIdx].linkedItems.count)
        case .calendar(var cal):
            guard let eIdx = cal.events.firstIndex(where: { $0.id == sourceItemId }) else {
                return .failure(.unknownSourceItem)
            }
            if cal.events[eIdx].linkedItems.contains(ref) {
                result = .success(cal.events[eIdx].linkedItems.count)
                return result
            }
            cal.events[eIdx].linkedItems.append(ref)
            bodyVal = .calendar(cal)
            result = .success(cal.events[eIdx].linkedItems.count)
        case .checklist(var cl):
            guard let iIdx = cl.items.firstIndex(where: { $0.id == sourceItemId }) else {
                return .failure(.unknownSourceItem)
            }
            if cl.items[iIdx].linkedItems.contains(ref) {
                result = .success(cl.items[iIdx].linkedItems.count)
                return result
            }
            cl.items[iIdx].linkedItems.append(ref)
            bodyVal = .checklist(cl)
            result = .success(cl.items[iIdx].linkedItems.count)
        case .slack, .empty, .calculator, .chart:
            return .failure(.unknownSource)
        }
        myApps[mIdx].components[cIdx].body = bodyVal
        persist()
        let src = ComponentItemRef(componentId: sourceComponentId, itemId: sourceItemId)
        let tgt = ComponentItemRef(componentId: targetComponentId, itemId: targetItemId)
        emitItemEvent(myAppId: target, componentId: sourceComponentId, kind: .linked, actor: .user,
                      itemId: sourceItemId, inverse: .linked(source: src, target: tgt))
        return result
    }

    /// Remove a ref from `(sourceComponentId, sourceItemId)`'s
    /// `linkedItems`. Returns the updated link count, or a
    /// `LinkMutationError` if source / target isn't found. Removing a
    /// ref that wasn't present succeeds with the unchanged count
    /// (idempotent).
    @discardableResult
    public func unlinkItems(
        sourceComponentId: String,
        sourceItemId: UUID,
        targetComponentId: String,
        targetItemId: UUID,
        myAppId: UUID? = nil
    ) -> Result<Int, LinkMutationError> {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else {
            return .failure(.unknownSource)
        }
        guard let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == sourceComponentId }) else {
            return .failure(.unknownSource)
        }
        var result: Result<Int, LinkMutationError> = .failure(.unknownSourceItem)
        var bodyVal = myApps[mIdx].components[cIdx].body
        var changed = false
        switch bodyVal {
        case .tracker(var t):
            guard let iIdx = t.items.firstIndex(where: { $0.id == sourceItemId }) else {
                return .failure(.unknownSourceItem)
            }
            let before = t.items[iIdx].linkedItems.count
            t.items[iIdx].linkedItems.removeAll(where: {
                $0.componentId == targetComponentId && $0.itemId == targetItemId
            })
            changed = before != t.items[iIdx].linkedItems.count
            if changed { bodyVal = .tracker(t) }
            result = .success(t.items[iIdx].linkedItems.count)
        case .calendar(var cal):
            guard let eIdx = cal.events.firstIndex(where: { $0.id == sourceItemId }) else {
                return .failure(.unknownSourceItem)
            }
            let before = cal.events[eIdx].linkedItems.count
            cal.events[eIdx].linkedItems.removeAll(where: {
                $0.componentId == targetComponentId && $0.itemId == targetItemId
            })
            changed = before != cal.events[eIdx].linkedItems.count
            if changed { bodyVal = .calendar(cal) }
            result = .success(cal.events[eIdx].linkedItems.count)
        case .checklist(var cl):
            guard let iIdx = cl.items.firstIndex(where: { $0.id == sourceItemId }) else {
                return .failure(.unknownSourceItem)
            }
            let before = cl.items[iIdx].linkedItems.count
            cl.items[iIdx].linkedItems.removeAll(where: {
                $0.componentId == targetComponentId && $0.itemId == targetItemId
            })
            changed = before != cl.items[iIdx].linkedItems.count
            if changed { bodyVal = .checklist(cl) }
            result = .success(cl.items[iIdx].linkedItems.count)
        case .slack, .empty, .calculator, .chart:
            return .failure(.unknownSource)
        }
        if changed {
            myApps[mIdx].components[cIdx].body = bodyVal
            persist()
            let src = ComponentItemRef(componentId: sourceComponentId, itemId: sourceItemId)
            let tgt = ComponentItemRef(componentId: targetComponentId, itemId: targetItemId)
            emitItemEvent(myAppId: target, componentId: sourceComponentId, kind: .unlinked, actor: .user,
                          itemId: sourceItemId, inverse: .unlinked(source: src, target: tgt))
        }
        return result
    }

    /// Internal: does `comp` contain an item with id `itemId`? Used by
    /// `linkItems` to validate the target before mutating the source so
    /// dangling refs can't enter `linkedItems` via the tool path. The
    /// view-layer resolver `displayNameForRefTarget` still handles
    /// dangling refs (rendering "(deleted)") for refs that became stale
    /// after a target was removed.
    private func itemExists(in comp: Component, itemId: UUID) -> Bool {
        switch comp.body {
        case .tracker(let t): return t.items.contains(where: { $0.id == itemId })
        case .calendar(let cal): return cal.events.contains(where: { $0.id == itemId })
        case .checklist(let cl): return cl.items.contains(where: { $0.id == itemId })
        case .slack, .empty, .calculator, .chart: return false
        }
    }

    /// Display name for a checklist item, used by inline pills that
    /// reference one. Trims whitespace and falls back to a stub when the
    /// item text is empty.
    public func displayNameForChecklistItem(
        componentId: String,
        itemId: UUID,
        myAppId: UUID? = nil
    ) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .checklist(let cl) = comp.body,
              let item = cl.items.first(where: { $0.id == itemId }) else { return nil }
        return item.text.nonEmpty ?? "(empty item)"
    }

    /// Display name for a calendar event, used by inline pills that
    /// reference one (today: from a checklist item's `linkedItems`).
    /// Returns the event's `title` (trimmed), or nil if no event matches
    /// — the pill then renders as "(deleted)".
    public func displayNameForCalendarEvent(
        componentId: String,
        eventId: UUID,
        myAppId: UUID? = nil
    ) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .calendar(let cal) = comp.body,
              let event = cal.events.first(where: { $0.id == eventId }) else { return nil }
        return event.title.nonEmpty ?? "(untitled event)"
    }

    /// Dispatch a `(componentId, itemId)` ref to the right per-kind
    /// resolver based on the target component's body. Used by inline-pill
    /// renderers that can reference either a tracker item or a calendar
    /// event without caring which.
    public func displayNameForRefTarget(
        componentId: String,
        itemId: UUID,
        myAppId: UUID? = nil
    ) -> String? {
        let target = myAppId ?? activeMyAppId
        guard let myApp = myApps.first(where: { $0.id == target }),
              let comp = myApp.components.first(where: { $0.id == componentId }) else { return nil }
        switch comp.body {
        case .tracker:
            return displayNameForTrackerItem(componentId: componentId, itemId: itemId, myAppId: myAppId)
        case .calendar:
            return displayNameForCalendarEvent(componentId: componentId, eventId: itemId, myAppId: myAppId)
        case .checklist:
            return displayNameForChecklistItem(componentId: componentId, itemId: itemId, myAppId: myAppId)
        case .slack, .empty, .calculator, .chart:
            return nil
        }
    }

    /// Kind string of a component by id, useful for inline-pill renderers
    /// that want to show a per-kind glyph or fall back to a generic one.
    public func componentKind(_ componentId: String, myAppId: UUID? = nil) -> String? {
        let target = myAppId ?? activeMyAppId
        return myApps.first(where: { $0.id == target })?
            .components.first(where: { $0.id == componentId })?
            .kindString
    }

    // MARK: - Undo

    public enum UndoError: Error, Codable, Sendable, Equatable {
        case eventNotFound
        case alreadyUndone
        case notReversible
        case itemNoLongerExists
        case componentNoLongerExists
        case inconsistentState

        public var stableCode: String {
            switch self {
            case .eventNotFound: return "event_not_found"
            case .alreadyUndone: return "already_undone"
            case .notReversible: return "not_reversible"
            case .itemNoLongerExists: return "item_no_longer_exists"
            case .componentNoLongerExists: return "component_no_longer_exists"
            case .inconsistentState: return "inconsistent_state"
            }
        }

        public var reason: String {
            switch self {
            case .eventNotFound: return "Event not found in history."
            case .alreadyUndone: return "Already undone."
            case .notReversible: return "Event has no recorded inverse (legacy event)."
            case .itemNoLongerExists: return "The affected item no longer exists."
            case .componentNoLongerExists: return "The affected component no longer exists."
            case .inconsistentState: return "Cannot apply inverse: canvas state is inconsistent."
            }
        }
    }

    @discardableResult
    public func undo(eventId: UUID) -> Result<Void, UndoError> {
        guard let event = itemEventLog.all.first(where: { $0.id == eventId }) else {
            return .failure(.eventNotFound)
        }
        guard !event.undone else { return .failure(.alreadyUndone) }
        guard !event.isUndo else { return .failure(.alreadyUndone) }
        guard let inverse = event.inverse() else { return .failure(.notReversible) }

        undoInProgress = true
        let result = executeInverse(inverse, myAppId: event.myAppId, componentId: event.componentId)
        undoInProgress = false
        if case .failure = result { return result }
        itemEventLog.markUndone(id: eventId)
        return .success(())
    }

    private func executeInverse(
        _ inverse: ItemEventInverse,
        myAppId: UUID,
        componentId: String
    ) -> Result<Void, UndoError> {
        switch inverse {
        case .trackerAdded(let itemId):
            guard itemExistsInTracker(itemId: itemId, myAppId: myAppId) else {
                return .failure(.itemNoLongerExists)
            }
            removeItem(id: itemId, myAppId: myAppId, componentId: componentId, actor: .user)

        case .trackerRemoved(let snapshot, let index):
            reinsertTrackerItem(snapshot, at: index, myAppId: myAppId, componentId: componentId)

        case .trackerPatched(let snapshot):
            guard itemExistsInTracker(itemId: snapshot.id, myAppId: myAppId) else {
                return .failure(.itemNoLongerExists)
            }
            let patch = snapshot.values
            _ = patchItem(id: snapshot.id, with: patch, myAppId: myAppId, componentId: componentId, actor: .user)
            // Restore linkedItems too — a patch undo restores the full prior snapshot
            _ = setTrackerItemLinkedItems(id: snapshot.id, refs: snapshot.linkedItems,
                                          myAppId: myAppId, componentId: componentId)

        case .calendarAdded(let itemId):
            guard calendarEventExists(itemId: itemId, myAppId: myAppId) else {
                return .failure(.itemNoLongerExists)
            }
            _ = removeCalendarEvent(id: itemId, myAppId: myAppId, componentId: componentId, actor: .user)

        case .calendarRemoved(let snapshot, let index):
            reinsertCalendarEvent(snapshot, at: index, myAppId: myAppId, componentId: componentId)

        case .calendarPatched(let snapshot):
            guard calendarEventExists(itemId: snapshot.id, myAppId: myAppId) else {
                return .failure(.itemNoLongerExists)
            }
            let eventPatch = CalendarEventPatch(
                title: snapshot.title,
                start: snapshot.start,
                end: .some(snapshot.end),
                location: .some(snapshot.location),
                notes: .some(snapshot.notes),
                linkedItems: snapshot.linkedItems
            )
            _ = patchCalendarEvent(id: snapshot.id, patch: eventPatch,
                                   myAppId: myAppId, componentId: componentId, actor: .user)

        case .checklistAdded(let itemId):
            guard checklistItemExists(itemId: itemId, myAppId: myAppId) else {
                return .failure(.itemNoLongerExists)
            }
            _ = removeChecklistItem(id: itemId, myAppId: myAppId, componentId: componentId, actor: .user)

        case .checklistRemoved(let snapshot, let index):
            reinsertChecklistItem(snapshot, at: index, myAppId: myAppId, componentId: componentId)

        case .checklistPatched(let snapshot):
            guard checklistItemExists(itemId: snapshot.id, myAppId: myAppId) else {
                return .failure(.itemNoLongerExists)
            }
            let itemPatch = ChecklistItemPatch(
                text: snapshot.text,
                done: snapshot.done,
                linkedItems: snapshot.linkedItems
            )
            _ = patchChecklistItem(id: snapshot.id, patch: itemPatch,
                                   myAppId: myAppId, componentId: componentId, actor: .user)

        case .linked(let src, let tgt):
            _ = unlinkItems(sourceComponentId: src.componentId, sourceItemId: src.itemId,
                            targetComponentId: tgt.componentId, targetItemId: tgt.itemId,
                            myAppId: myAppId)

        case .unlinked(let src, let tgt):
            _ = linkItems(sourceComponentId: src.componentId, sourceItemId: src.itemId,
                          targetComponentId: tgt.componentId, targetItemId: tgt.itemId,
                          myAppId: myAppId)

        case .componentAdded(let compId):
            guard componentExists(compId, myAppId: myAppId) else {
                return .failure(.componentNoLongerExists)
            }
            _ = removeComponent(componentId: compId, myAppId: myAppId)

        case .componentRemoved(let snapshot, let index):
            reinsertComponent(snapshot, at: index, myAppId: myAppId)
        }
        return .success(())
    }

    // MARK: - Undo reinsert helpers

    private func reinsertTrackerItem(_ item: TrackerItem, at index: Int, myAppId: UUID, componentId: String) {
        var inserted = false
        mutate(myAppId: myAppId, byComponentId: componentId) { canvas in
            guard case .tracker(var t) = canvas else { return false }
            guard !t.items.contains(where: { $0.id == item.id }) else { return false }
            let insertIdx = min(index, t.items.count)
            t.items.insert(item, at: insertIdx)
            canvas = .tracker(t)
            inserted = true
            return true
        }
        if inserted {
            emitItemEvent(myAppId: myAppId, componentId: componentId, kind: .added, actor: .user,
                          itemId: item.id, inverse: .trackerAdded(itemId: item.id))
        }
    }

    private func reinsertCalendarEvent(_ event: CalendarEvent, at index: Int, myAppId: UUID, componentId: String) {
        var inserted = false
        mutate(myAppId: myAppId, byComponentId: componentId) { canvas in
            guard case .calendar(var c) = canvas else { return false }
            guard !c.events.contains(where: { $0.id == event.id }) else { return false }
            let idx = min(index, c.events.count)
            c.events.insert(event, at: idx)
            canvas = .calendar(c)
            inserted = true
            return true
        }
        if inserted {
            emitItemEvent(myAppId: myAppId, componentId: componentId, kind: .added, actor: .user,
                          itemId: event.id, inverse: .calendarAdded(itemId: event.id))
        }
    }

    private func reinsertChecklistItem(_ item: ChecklistItem, at index: Int, myAppId: UUID, componentId: String) {
        var inserted = false
        mutate(myAppId: myAppId, byComponentId: componentId) { canvas in
            guard case .checklist(var cl) = canvas else { return false }
            guard !cl.items.contains(where: { $0.id == item.id }) else { return false }
            let idx = min(index, cl.items.count)
            cl.items.insert(item, at: idx)
            canvas = .checklist(cl)
            inserted = true
            return true
        }
        if inserted {
            emitItemEvent(myAppId: myAppId, componentId: componentId, kind: .added, actor: .user,
                          itemId: item.id, inverse: .checklistAdded(itemId: item.id))
        }
    }

    private func reinsertComponent(_ component: Component, at index: Int, myAppId: UUID) {
        guard let mIdx = myApps.firstIndex(where: { $0.id == myAppId }) else { return }
        guard !myApps[mIdx].components.contains(where: { $0.id == component.id }) else { return }
        let idx = min(index, myApps[mIdx].components.count)
        myApps[mIdx].components.insert(component, at: idx)
        persist()
        emitItemEvent(myAppId: myAppId, componentId: component.id, kind: .added, actor: .user,
                      inverse: .componentAdded(componentId: component.id))
    }

    // MARK: - Undo existence checks

    private func itemExistsInTracker(itemId: UUID, myAppId: UUID) -> Bool {
        guard let myApp = myApps.first(where: { $0.id == myAppId }) else { return false }
        return myApp.components.contains { comp in
            if case .tracker(let t) = comp.body { return t.items.contains(where: { $0.id == itemId }) }
            return false
        }
    }

    private func calendarEventExists(itemId: UUID, myAppId: UUID) -> Bool {
        guard let myApp = myApps.first(where: { $0.id == myAppId }) else { return false }
        return myApp.components.contains { comp in
            if case .calendar(let c) = comp.body { return c.events.contains(where: { $0.id == itemId }) }
            return false
        }
    }

    private func checklistItemExists(itemId: UUID, myAppId: UUID) -> Bool {
        guard let myApp = myApps.first(where: { $0.id == myAppId }) else { return false }
        return myApp.components.contains { comp in
            if case .checklist(let cl) = comp.body { return cl.items.contains(where: { $0.id == itemId }) }
            return false
        }
    }

    private func componentExists(_ componentId: String, myAppId: UUID) -> Bool {
        myApps.first(where: { $0.id == myAppId })?.components.contains(where: { $0.id == componentId }) ?? false
    }

    // MARK: - Change summary

    /// Human-readable one-line description for an event. Used by both the
    /// History sheet and the `listChanges` agent tool so they stay in sync.
    public func changeSummary(for event: ItemEvent) -> String {
        let kindLabel: String
        switch event.kind {
        case .added: kindLabel = "Added"
        case .patched: kindLabel = "Updated"
        case .removed: kindLabel = "Removed"
        case .linked: kindLabel = "Linked"
        case .unlinked: kindLabel = "Unlinked"
        }

        guard let inverse = event.inverse() else {
            return "\(kindLabel) item"
        }

        switch inverse {
        case .trackerAdded, .trackerRemoved, .trackerPatched:
            if let snap = trackerSnapshotName(from: inverse) {
                return "\(kindLabel) \"\(snap)\""
            }
            return "\(kindLabel) row"
        case .calendarAdded, .calendarRemoved, .calendarPatched:
            if let snap = calendarSnapshotName(from: inverse) {
                return "\(kindLabel) \"\(snap)\""
            }
            return "\(kindLabel) event"
        case .checklistAdded, .checklistRemoved, .checklistPatched:
            if let snap = checklistSnapshotName(from: inverse) {
                return "\(kindLabel) \"\(snap)\""
            }
            return "\(kindLabel) item"
        case .linked(_, let tgt):
            return "Linked -> \(tgt.componentId)"
        case .unlinked(_, let tgt):
            return "Unlinked from \(tgt.componentId)"
        case .componentAdded(let id):
            return "Added component \(id)"
        case .componentRemoved(let snap, _):
            return "Removed component \"\(snap.name)\""
        }
    }

    private func trackerSnapshotName(from inverse: ItemEventInverse) -> String? {
        switch inverse {
        case .trackerRemoved(let snap, _): return snap.displayName
        case .trackerPatched(let snap): return snap.displayName
        default: return nil
        }
    }

    private func calendarSnapshotName(from inverse: ItemEventInverse) -> String? {
        switch inverse {
        case .calendarRemoved(let snap, _): return snap.displayName
        case .calendarPatched(let snap): return snap.displayName
        default: return nil
        }
    }

    private func checklistSnapshotName(from inverse: ItemEventInverse) -> String? {
        switch inverse {
        case .checklistRemoved(let snap, _): return snap.displayName
        case .checklistPatched(let snap): return snap.displayName
        default: return nil
        }
    }

    // MARK: - Event log

    #if DEBUG
    func appendEventForTesting(_ event: ItemEvent) {
        itemEventLog.append(event)
    }
    #endif

    private func emitItemEvent(
        myAppId: UUID?,
        componentId: String,
        kind: ItemEventKind,
        actor: ItemEventActor,
        itemId: UUID? = nil,
        inverse: ItemEventInverse? = nil,
        isUndo: Bool = false
    ) {
        let target = myAppId ?? activeMyAppId
        let threadId = myApps.first(where: { $0.id == target })?.currentThreadId
        let payload: Data
        if let inverse, let data = try? JSONEncoder().encode(inverse) {
            payload = data
        } else {
            payload = Data()
        }
        itemEventLog.append(ItemEvent(
            myAppId: target,
            componentId: componentId,
            kind: kind,
            payload: payload,
            actor: actor,
            itemId: itemId,
            threadId: threadId,
            isUndo: isUndo || undoInProgress
        ))
    }

    // MARK: - Persistence

    /// Mutate the body of one component inside `myAppId`. Component
    /// selection rules:
    ///
    /// - If `kind` is given, target the first component whose body matches
    ///   that kind, preferring the active component when it matches. Empty
    ///   (uninitialised) components are accepted as fallbacks so constructor
    ///   mutators (`setTracker`, `setCalendar`) can initialise a freshly
    ///   added empty component on first render — once the body has been
    ///   replaced with a typed canvas, subsequent kind-matching mutators see
    ///   the same component and re-use it directly.
    /// - If `kind` is nil, target the active component (or first, as fallback).
    private func mutate(
        _ myAppId: UUID?,
        kind: String?,
        _ body: (inout CanvasApp) -> Bool
    ) {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else { return }
        let m = myApps[mIdx]

        let cIdx: Int?
        if let kind {
            // Priority: active component if it already matches the kind,
            // else any existing component of that kind, else active if empty,
            // else first empty component.
            let activeIdx = m.activeComponentId.flatMap { id in
                m.components.firstIndex(where: { $0.id == id })
            }
            if let active = activeIdx, m.components[active].kindString == kind {
                cIdx = active
            } else if let matching = m.components.firstIndex(where: { $0.kindString == kind }) {
                cIdx = matching
            } else if let active = activeIdx, m.components[active].kindString == "empty" {
                cIdx = active
            } else {
                cIdx = m.components.firstIndex(where: { $0.kindString == "empty" })
            }
        } else if let activeId = m.activeComponentId,
                  let active = m.components.firstIndex(where: { $0.id == activeId }) {
            cIdx = active
        } else {
            cIdx = m.components.isEmpty ? nil : 0
        }

        guard let cIdx else { return }
        var bodyVal = myApps[mIdx].components[cIdx].body
        let changed = body(&bodyVal)
        guard changed else { return }
        myApps[mIdx].components[cIdx].body = bodyVal
        persist()
    }

    /// Mutate a specific component by id, bypassing the kind-preference
    /// resolution that `mutate(_:kind:_:)` uses. Needed for cross-component
    /// edits (e.g. tapping a linked-item pill that points at a tracker
    /// other than the currently active one).
    private func mutate(
        myAppId: UUID?,
        byComponentId componentId: String,
        _ body: (inout CanvasApp) -> Bool
    ) {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else { return }
        guard let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == componentId }) else { return }
        var bodyVal = myApps[mIdx].components[cIdx].body
        let changed = body(&bodyVal)
        guard changed else { return }
        myApps[mIdx].components[cIdx].body = bodyVal
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            myApps: myApps,
            activeId: activeMyAppId,
            memoryThreads: memoryThreads,
            memoryCurrentThreadId: memoryCurrentThreadId,
            itemEventLog: itemEventLog
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private struct Snapshot: Codable {
        var myApps: [MyApp]
        var activeId: UUID
        var memoryThreads: [ChatThread]
        var memoryCurrentThreadId: String
        var itemEventLog: ItemEventLog?
    }

    private static func load() -> (myApps: [MyApp], activeId: UUID, memoryThreads: [ChatThread], memoryCurrentThreadId: String, itemEventLog: ItemEventLog) {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: storageKey),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
           !snap.myApps.isEmpty {
            let active = snap.myApps.contains(where: { $0.id == snap.activeId }) ? snap.activeId : snap.myApps[0].id
            var log = snap.itemEventLog ?? ItemEventLog()
            log.prune()
            return (snap.myApps, active, snap.memoryThreads, snap.memoryCurrentThreadId, log)
        }

        let myApp = WellbeingCoachExample.make()
        let firstThread = ChatThread()
        let snap = Snapshot(
            myApps: [myApp],
            activeId: myApp.id,
            memoryThreads: [firstThread],
            memoryCurrentThreadId: firstThread.id
        )
        if let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: storageKey)
        }
        return (snap.myApps, snap.activeId, snap.memoryThreads, snap.memoryCurrentThreadId, ItemEventLog())
    }

    public static func clearStorage() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

extension String {
    /// `self` if non-empty after trimming whitespace, else `nil`. Used by
    /// the calendar event resolver so a tracker item's missing or blank
    /// field falls through to the event's snapshot instead of overriding
    /// it with an empty string.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
