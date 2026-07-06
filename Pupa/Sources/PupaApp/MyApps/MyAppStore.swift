import Foundation
import Observation

/// Top-level store for the user's myapps. Replaces the old singleton
/// `CanvasState` — every canvas mutation routes through here against the
/// active myapp.
///
/// Persistence is **per-file** under the active storage root's `state/`
/// folder (`PupaStorage`): one `apps/<uuid>.json` per MyApp plus an
/// `index.json` (active id, order, orchestrator threads, audit log). One
/// mutation rewrites only the touched file, so iCloud syncs minimal traffic
/// and per-app snapshots stay cheap. On first launch under a fresh install
/// (no `state/`), `load()` seeds the pre-populated "Daily Briefing"
/// workspace via `DailyBriefingExample.make()` — a working demo of the
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
    /// Per-app encoded-blob hashes; lets `persist()` skip unchanged files so
    /// only the mutated MyApp re-syncs.
    private var lastAppHash: [UUID: Int] = [:]
    private var lastIndexHash: Int?

    public private(set) var myApps: [MyApp]
    public private(set) var activeMyAppId: UUID
    /// The global memory store, wired by `AppView` at startup. Memories are
    /// keyed on the app-name slug, so `renameMyApp` must move the folder
    /// through this store. Unset in previews/tests that never touch memories.
    @ObservationIgnored public var globalMemory: MemoryStore?
    /// Thread list for the Orchestrator (memory-scope) chat. Always non-empty.
    public private(set) var memoryThreads: [ChatThread]
    /// The threadId of the currently-selected Orchestrator conversation.
    public private(set) var memoryCurrentThreadId: String
    /// Append-only change feed of item mutations. Persisted in `index.json`;
    /// live-observable so the History sheet updates. Captions the timeline;
    /// state is restored from `SnapshotStore`, not replayed from this.
    public private(set) var itemEventLog = ItemEventLog()
    /// Coalesces bursts of edits into one debounced `SnapshotStore` capture
    /// per MyApp, keyed by app id.
    private var pendingSnapshotTasks: [UUID: Task<Void, Never>] = [:]

    public init(initial: ([MyApp], UUID)? = nil) {
        if let initial {
            self.myApps = initial.0
            self.activeMyAppId = initial.1
            let first = ChatThread()
            self.memoryThreads = [first]
            self.memoryCurrentThreadId = first.id
        } else {
            let loaded = Self.load()
            self.myApps = loaded.myApps
            self.activeMyAppId = loaded.activeId
            self.memoryThreads = loaded.memoryThreads
            self.memoryCurrentThreadId = loaded.memoryCurrentThreadId
            self.itemEventLog = loaded.itemEventLog
            // Seed disk on fresh install; otherwise prime hashes so the first
            // mutation only writes the app that actually changed. On fresh
            // install also ship default skills into the seeded app (app-birth
            // is the only time we seed — see `DefaultSkills`).
            if loaded.fromDisk {
                primeHashes()
            } else {
                for app in myApps { seedBirthFiles(forAppNamed: app.name) }
                persist()
            }
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

    // MARK: - Per-agent disabled tools

    /// Storage key for the main agent's per-MyApp disabled tool names. Stored
    /// under `MyApp.settings` as a `.stringArray`. Unioned with the global
    /// `disabledBackendTools` set at send time — never an override.
    public static let disabledToolsSettingsKey = "tools.disabled"

    /// Write (or clear) the main agent's per-MyApp disabled tool set. Empty
    /// clears the key.
    public func setMyAppDisabledTools(_ names: Set<String>, for myAppId: UUID) {
        guard let idx = myApps.firstIndex(where: { $0.id == myAppId }) else { return }
        if names.isEmpty {
            myApps[idx].settings.removeValue(forKey: Self.disabledToolsSettingsKey)
        } else {
            myApps[idx].settings[Self.disabledToolsSettingsKey] = .stringArray(names.sorted())
        }
        persist()
    }

    /// Read the main agent's per-MyApp disabled tool set. Empty when unset.
    public func myAppDisabledTools(for myAppId: UUID) -> Set<String> {
        guard let myApp = myApps.first(where: { $0.id == myAppId }),
              case .stringArray(let names) = myApp.settings[Self.disabledToolsSettingsKey] else { return [] }
        return Set(names)
    }

    public func setActive(_ id: UUID) {
        guard myApps.contains(where: { $0.id == id }), id != activeMyAppId else { return }
        activeMyAppId = id
        persist()
    }

    /// Creation-order index of a myApp, used to pick its palette color via
    /// `Color.color(atIndex:)`. Sorting by `createdAt` keeps a myApp's color
    /// stable as others are added/removed.
    public func colorIndex(for myAppId: UUID) -> Int {
        myApps.sorted { $0.createdAt < $1.createdAt }
            .firstIndex(where: { $0.id == myAppId }) ?? 0
    }

    // MARK: - Lifecycle

    /// One-time, at-birth seeding for a freshly created/restored app: the
    /// universal default skills plus (when the name matches an example) its
    /// persona AGENTS.md. Never run on plain launches, so user edits and
    /// deletions of these files survive. The chat coordinator rescans the
    /// global sidebar on the next app-scoped write, so no `globalMemory` here.
    private func seedBirthFiles(forAppNamed name: String) {
        DefaultSkills.seed(appName: name)
        ExampleRegistry.seedAgentsMd(forAppNamed: name)
    }

    @discardableResult
    public func addMyApp(typeId: String, name: String, iconSystemName: String) -> UUID {
        let myApp = MyApp(
            name: name.isEmpty ? "New myapp" : name,
            iconSystemName: iconSystemName,
            typeId: typeId
        )
        myApps.append(myApp)
        seedBirthFiles(forAppNamed: myApp.name)
        activeMyAppId = myApp.id
        persist()
        return myApp.id
    }

    public func renameMyApp(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = myApps.firstIndex(where: { $0.id == id }) else { return }
        let oldName = myApps[idx].name
        guard oldName != trimmed else { return }
        myApps[idx].name = trimmed
        // Memories live under the name's slug — move them along or they're
        // orphaned (empty Memories tab, exports ship no memories).
        globalMemory?.migrateAppFolder(fromAppNamed: oldName, toAppNamed: trimmed)
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

    /// Re-insert the seeded "Job Search" workspace if the user
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
        seedBirthFiles(forAppNamed: myApp.name)
        activeMyAppId = myApp.id
        persist()
        return myApp.id
    }

    /// Insert a fully-formed `MyApp` produced by `MyAppImporter` (marketplace
    /// import). Unlike `restoreExample` this performs no by-name idempotency:
    /// the importer has already reassigned the `id` and resolved name/slug
    /// collisions, so the app is appended verbatim and made active. Memories
    /// are written separately by the importer. Returns the inserted id.
    @discardableResult
    public func importMyApp(_ myApp: MyApp) -> UUID {
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

    /// Write (or clear) a thread's per-thread LLM override atomically. Pass
    /// `nil` for either field to clear both — the pair only ever applies
    /// together. A cleared thread re-inherits its scope's default. Locates the
    /// thread in `memoryThreads` / `myApps[…].threads` like `setThreadTitle`.
    public func setThreadLLM(provider: String?, model: String?, threadId: String, for scope: ChatScope) {
        let pair: (String, String)? = {
            if let provider, let model, !provider.isEmpty, !model.isEmpty { return (provider, model) }
            return nil
        }()
        switch scope {
        case .memory:
            guard let idx = memoryThreads.firstIndex(where: { $0.id == threadId }) else { return }
            memoryThreads[idx].llmProvider = pair?.0
            memoryThreads[idx].llmModel = pair?.1
        case .myApp(let id):
            guard let mIdx = myApps.firstIndex(where: { $0.id == id }),
                  let tIdx = myApps[mIdx].threads.firstIndex(where: { $0.id == threadId }) else { return }
            myApps[mIdx].threads[tIdx].llmProvider = pair?.0
            myApps[mIdx].threads[tIdx].llmModel = pair?.1
        }
        persist()
    }

    /// Read a thread's per-thread LLM override. Returns `nil` when either field
    /// is missing — callers fall back to the scope default, then the backend
    /// env default.
    public func threadLLM(threadId: String, for scope: ChatScope) -> (provider: String, model: String)? {
        let thread: ChatThread?
        switch scope {
        case .memory:
            thread = memoryThreads.first(where: { $0.id == threadId })
        case .myApp(let id):
            thread = myApps.first(where: { $0.id == id })?.threads.first(where: { $0.id == threadId })
        }
        guard let provider = thread?.llmProvider, let model = thread?.llmModel else { return nil }
        return (provider, model)
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
        emitItemEvent(myAppId: target, componentId: id, kind: .added, actor: .user)
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
        guard !refuseIfLocked(mIdx, cIdx) else { return false }
        myApps[mIdx].components.remove(at: cIdx)
        if myApps[mIdx].activeComponentId == componentId {
            myApps[mIdx].activeComponentId = myApps[mIdx].components.first?.id
        }
        persist()
        emitItemEvent(myAppId: target, componentId: componentId, kind: .removed, actor: .user)
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

    /// Edit a component's mutable metadata in place — `name`, `iconSystemName`,
    /// and the LLM-facing `summary` (the "what this is for" description). The
    /// component `id` and `body` (its data) are untouched, so this never loses
    /// content the way delete-and-re-add would. Each argument is optional:
    /// `nil` leaves that field alone; a value sets it (an all-whitespace `name`
    /// or `iconSystemName` is ignored, an all-whitespace `summary` clears it,
    /// matching `setComponentSummary`). Returns `true` iff anything changed.
    @discardableResult
    public func updateComponentMeta(
        componentId: String,
        name: String? = nil,
        iconSystemName: String? = nil,
        summary: String? = nil,
        myAppId: UUID? = nil
    ) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }),
              let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == componentId })
        else { return false }

        var changed = false
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, myApps[mIdx].components[cIdx].name != trimmed {
                myApps[mIdx].components[cIdx].name = trimmed
                changed = true
            }
        }
        if let iconSystemName {
            let trimmed = iconSystemName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, myApps[mIdx].components[cIdx].iconSystemName != trimmed {
                myApps[mIdx].components[cIdx].iconSystemName = trimmed
                changed = true
            }
        }
        if let summary {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let next: String? = trimmed.isEmpty ? nil : trimmed
            if myApps[mIdx].components[cIdx].summary != next {
                myApps[mIdx].components[cIdx].summary = next
                changed = true
            }
        }
        if changed { persist() }
        return changed
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
                          itemId: item.id)
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
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.items.firstIndex(where: { $0.id == id }) else { return false }
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: id)
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
                          itemId: removedItem.id)
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
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .tracker(var t) = canvas,
                  let idx = t.items.firstIndex(where: { $0.id == id }) else { return false }
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id)
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: prior?.id)
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
                          itemId: event.id)
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
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calendar(var c) = canvas,
                  let idx = c.events.firstIndex(where: { $0.id == id }) else { return false }
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: id)
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
        var after: CalendarEvent?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calendar(var c) = canvas,
                  let idx = c.events.firstIndex(where: { $0.id == id }) else { return false }
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id)
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
            // Sweep every ref kind (linkedItems graph + calculator spec refs)
            // through the unified ref model: keep all components, drop only the
            // deleted item. Single source of truth shared with the exporter.
            myApps[mIdx].components[cIdx].body.remapReferences(
                keepComponent: { _ in true },
                keepItem: { !($0.componentId == componentId && $0.itemId == itemId) }
            )
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
                          itemId: item.id)
        }
        return added
    }

    /// Flip the `done` flag of a checklist item. Returns the new value,
    /// or nil if the item isn't found.
    @discardableResult
    public func toggleChecklistItem(id: UUID, myAppId: UUID? = nil, actor: ItemEventActor = .user) -> Bool? {
        let compId = checklistComponentId(myAppId: myAppId)
        var newValue: Bool?
        mutate(myAppId, kind: "checklist") { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }) else { return false }
            cl.items[idx].done.toggle()
            newValue = cl.items[idx].done
            canvas = .checklist(cl)
            return true
        }
        if newValue != nil, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id)
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
        var after: ChecklistItem?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }) else { return false }
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor,
                          itemId: id)
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
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .checklist(var cl) = canvas,
                  let idx = cl.items.firstIndex(where: { $0.id == id }) else { return false }
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
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .removed, actor: actor,
                          itemId: id)
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

    /// Set (or clear) the linked tracker item a `linkedField` row pulls from.
    /// This is the "swap the house" mutator — backing both the row's link pill
    /// and the `setCalcRowLink` tool. No-op (no event) if the row isn't a
    /// `linkedField` or the ref is unchanged. `ref == nil` clears the link
    /// (the row then resolves to `brokenRef`).
    @discardableResult
    public func setCalcRowLinkedRef(
        key: String,
        ref: ComponentItemRef?,
        myAppId: UUID? = nil,
        componentId: String? = nil,
        actor: ItemEventActor = .user
    ) -> Bool {
        let compId = componentId ?? calculatorComponentId(myAppId: myAppId)
        var patchedId: UUID?
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calculator(var c) = canvas,
                  let idx = c.rows.firstIndex(where: { $0.key == key }),
                  case .linkedField(var spec) = c.rows[idx].kind,
                  spec.ref != ref else { return false }
            spec.ref = ref
            c.rows[idx].kind = .linkedField(spec)
            patchedId = c.rows[idx].id
            canvas = .calculator(c)
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "calculator", body)
        }
        if let patchedId, let compId {
            emitItemEvent(myAppId: myAppId, componentId: compId, kind: .patched, actor: actor, itemId: patchedId)
        }
        return patchedId != nil
    }

    /// Point EVERY `linkedField` row at one tracker item at once — the "pick
    /// the source, the whole model follows" selector backing the calculator's
    /// single-source dropdown. Only repoints rows that target the SAME tracker
    /// as `ref` (matching `componentId`, or rows whose ref is currently nil),
    /// so a calculator mixing two trackers stays coherent. Emits no item event
    /// (like `setCalculatorVariable`) so flipping the dropdown doesn't flood
    /// History. Returns the number of rows repointed.
    @discardableResult
    public func setAllCalcRowLinks(
        to ref: ComponentItemRef,
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> Int {
        var count = 0
        let body: (inout CanvasApp) -> Bool = { canvas in
            guard case .calculator(var c) = canvas else { return false }
            var changed = false
            for idx in c.rows.indices {
                guard case .linkedField(var spec) = c.rows[idx].kind else { continue }
                // Leave rows bound to a different tracker untouched.
                if let existing = spec.ref, existing.componentId != ref.componentId { continue }
                if spec.ref == ref { continue }
                spec.ref = ref
                c.rows[idx].kind = .linkedField(spec)
                changed = true
                count += 1
            }
            guard changed else { return false }
            canvas = .calculator(c)
            return true
        }
        if let componentId {
            mutate(myAppId: myAppId, byComponentId: componentId, body)
        } else {
            mutate(myAppId, kind: "calculator", body)
        }
        return count
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
    //
    // Slack agents are filesystem subagents (`pupa/agents/<slug>/AGENTS.md`);
    // the roster is not stored in `SlackData`. These mutators therefore take
    // member/author identifiers as subagent slugs verbatim — validation
    // against the real roster (via `AgentStore`) is the caller's job.

    /// Append a `SlackChannel` to the Slack body. Returns the generated
    /// stable id. `memberAgentIds` are subagent slugs, stored as given.
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
            let id = Self.nextSlackId(prefix: "channel", existing: s.channels.map(\.id))
            s.channels.append(SlackChannel(
                id: id,
                name: trimmed,
                type: type,
                memberAgentIds: memberAgentIds
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

    /// Add agents (subagent slugs) to a channel's member roster. Idempotent
    /// — already-present slugs are skipped. Returns true if at least one new
    /// slug was appended.
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
            var existing = Set(s.channels[cIdx].memberAgentIds)
            var localChanged = false
            for id in agentIds where existing.insert(id).inserted {
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

    /// Find-or-create a 1-on-1 DM channel with a subagent (`agentId` = its
    /// slug). A DM is the unique channel whose `type == .dm` and
    /// `memberAgentIds == [agentId]` — when the user clicks an agent in the
    /// sidebar we either jump to that channel or create it, named
    /// `displayName` (the subagent's label). Returns the channel id.
    @discardableResult
    public func slackOpenDM(
        agentId: String,
        displayName: String,
        myAppId: UUID? = nil,
        componentId: String? = nil
    ) -> String? {
        var resolvedId: String?
        let mutator: (inout CanvasApp) -> Bool = { canvas in
            guard case .slack(var s) = canvas else { return false }
            if let existing = s.channels.first(where: {
                $0.type == .dm && $0.memberAgentIds == [agentId]
            }) {
                resolvedId = existing.id
                return false
            }
            let id = Self.nextSlackId(prefix: "channel", existing: s.channels.map(\.id))
            s.channels.append(SlackChannel(
                id: id,
                name: displayName,
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
        /// The source component is locked; mutation refused.
        case locked
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
        guard !refuseIfLocked(mIdx, cIdx) else { return .failure(.locked)
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
        emitItemEvent(myAppId: target, componentId: sourceComponentId, kind: .linked, actor: .user,
                      itemId: sourceItemId)
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
        guard !refuseIfLocked(mIdx, cIdx) else { return .failure(.locked) }
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
            emitItemEvent(myAppId: target, componentId: sourceComponentId, kind: .unlinked, actor: .user,
                          itemId: sourceItemId)
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

    // MARK: - Change summary

    /// Human-readable one-line label for a change-feed event. Snapshots are
    /// the restore unit now, so this is a lightweight timeline caption
    /// (verb + component-kind noun), not a reversible descriptor.
    public func changeSummary(for event: ItemEvent) -> String {
        let verb: String
        switch event.kind {
        case .added: verb = "Added"
        case .patched: verb = "Updated"
        case .removed: verb = "Removed"
        case .linked: return "Linked items"
        case .unlinked: return "Unlinked items"
        case .restored: return "Restored an earlier version"
        case .locked: return "Locked a component"
        case .unlocked: return "Unlocked a component"
        }
        let noun: String
        switch componentKind(event.componentId, myAppId: event.myAppId) {
        case "tracker": noun = "row"
        case "calendar": noun = "event"
        case "checklist", "slack": noun = "item"
        default: noun = event.itemId == nil ? "component" : "item"
        }
        return "\(verb) \(noun)"
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
        itemId: UUID? = nil
    ) {
        let target = myAppId ?? activeMyAppId
        let threadId = myApps.first(where: { $0.id == target })?.currentThreadId
        itemEventLog.append(ItemEvent(
            myAppId: target,
            componentId: componentId,
            kind: kind,
            actor: actor,
            itemId: itemId,
            threadId: threadId
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
        guard !refuseIfLocked(mIdx, cIdx) else { return }
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
        guard !refuseIfLocked(mIdx, cIdx) else { return }
        var bodyVal = myApps[mIdx].components[cIdx].body
        let changed = body(&bodyVal)
        guard changed else { return }
        myApps[mIdx].components[cIdx].body = bodyVal
        persist()
    }

    // MARK: - Component lock

    /// Set on any mutation refused because its target component is locked.
    /// The tool layer reads this to surface a "locked" result to the agent
    /// (see `AppTools`); reset it before each tool handler runs.
    public private(set) var lastWriteBlockedByLock = false

    public func resetLockFlag() { lastWriteBlockedByLock = false }

    /// True (and records the block) when component `cIdx` of app `mIdx` is
    /// locked — the single write backstop shared by both `mutate` variants
    /// and the structural (remove / link) guards.
    private func refuseIfLocked(_ mIdx: Int, _ cIdx: Int) -> Bool {
        guard myApps[mIdx].components[cIdx].isLocked else { return false }
        lastWriteBlockedByLock = true
        return true
    }

    /// Whether a component is locked. `componentId` nil → the app's active
    /// component. Used by the lock toggle UI and view-layer edit gating.
    public func isComponentLocked(componentId: String? = nil, myAppId: UUID? = nil) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let m = myApps.first(where: { $0.id == target }) else { return false }
        let cid = componentId ?? m.activeComponentId
        return m.components.first(where: { $0.id == cid })?.isLocked ?? false
    }

    /// Lock or unlock a component. Edits the flag directly (never gated — this
    /// is the unlock path), persists, and captions the change feed.
    @discardableResult
    public func setComponentLocked(componentId: String, locked: Bool, myAppId: UUID? = nil) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }),
              let cIdx = myApps[mIdx].components.firstIndex(where: { $0.id == componentId }),
              myApps[mIdx].components[cIdx].isLocked != locked
        else { return false }
        myApps[mIdx].components[cIdx].isLocked = locked
        persist()
        emitItemEvent(myAppId: target, componentId: componentId,
                      kind: locked ? .locked : .unlocked, actor: .user)
        return true
    }

    /// Lock or unlock every component of a MyApp at once (the MyApp-level
    /// lock surfaced on the home page). Returns false when nothing changed.
    @discardableResult
    public func setAllComponentsLocked(locked: Bool, myAppId: UUID? = nil) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let mIdx = myApps.firstIndex(where: { $0.id == target }) else { return false }
        var changed = false
        for i in myApps[mIdx].components.indices where myApps[mIdx].components[i].isLocked != locked {
            myApps[mIdx].components[i].isLocked = locked
            changed = true
        }
        guard changed else { return false }
        persist()
        emitItemEvent(myAppId: target, componentId: myApps[mIdx].components.first?.id ?? "",
                      kind: locked ? .locked : .unlocked, actor: .user)
        return true
    }

    /// Whether every component of a MyApp is locked (drives the home
    /// lock toggle's state). False for a MyApp with no components.
    public func areAllComponentsLocked(myAppId: UUID? = nil) -> Bool {
        let target = myAppId ?? activeMyAppId
        guard let m = myApps.first(where: { $0.id == target }), !m.components.isEmpty else { return false }
        return m.components.allSatisfy { $0.isLocked }
    }

    // MARK: - Per-file persistence

    private nonisolated static var stateRoot: URL { PupaStorage.stateRoot }
    private nonisolated static var appsDir: URL { stateRoot.appendingPathComponent("apps", isDirectory: true) }
    private nonisolated static var indexURL: URL { stateRoot.appendingPathComponent("index.json") }
    private nonisolated static func appURL(_ id: UUID) -> URL {
        appsDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// `index.json` — everything that isn't a single MyApp body.
    private struct IndexFile: Codable {
        var order: [UUID]
        var activeId: UUID
        var memoryThreads: [ChatThread]
        var memoryCurrentThreadId: String
        var itemEventLog: ItemEventLog?
    }

    /// Encoder for persisted state. `.sortedKeys` makes the bytes
    /// deterministic — Foundation's default key order can differ between
    /// encodes of the same value, which would fail the dirty-hash skip and
    /// rewrite (re-upload) every unchanged app file.
    private static func stateEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }

    /// Write only the files whose encoded bytes changed; delete files for
    /// removed apps. Writes are plain atomic via `CloudDocument` (no main-thread
    /// file coordination); each schedules a background `StorageMirror` pass.
    private func persist() {
        let enc = Self.stateEncoder()
        var live = Set<UUID>()
        for app in myApps {
            live.insert(app.id)
            guard let data = try? enc.encode(app) else { continue }
            let h = data.hashValue
            if lastAppHash[app.id] == h { continue }
            try? CloudDocument.write(data, to: Self.appURL(app.id))
            lastAppHash[app.id] = h
            // Coalesce this edit into a debounced snapshot for History.
            scheduleSnapshot(app.id)
        }
        for gone in Set(lastAppHash.keys).subtracting(live) {
            CloudDocument.delete(Self.appURL(gone))
            SnapshotStore.deleteAll(gone)
            pendingSnapshotTasks[gone]?.cancel()
            pendingSnapshotTasks[gone] = nil
            lastAppHash[gone] = nil
        }
        let index = IndexFile(
            order: myApps.map(\.id),
            activeId: activeMyAppId,
            memoryThreads: memoryThreads,
            memoryCurrentThreadId: memoryCurrentThreadId,
            itemEventLog: itemEventLog
        )
        if let data = try? enc.encode(index), data.hashValue != lastIndexHash {
            try? CloudDocument.write(data, to: Self.indexURL)
            lastIndexHash = data.hashValue
        }
    }

    /// Fill the dirty-hash caches from current state without writing, so the
    /// next mutation only re-encodes/uploads the file that changed.
    private func primeHashes() {
        let enc = Self.stateEncoder()
        for app in myApps {
            if let data = try? enc.encode(app) { lastAppHash[app.id] = data.hashValue }
        }
        let index = IndexFile(
            order: myApps.map(\.id), activeId: activeMyAppId,
            memoryThreads: memoryThreads, memoryCurrentThreadId: memoryCurrentThreadId,
            itemEventLog: itemEventLog)
        lastIndexHash = (try? enc.encode(index))?.hashValue
    }

    private struct Loaded {
        var myApps: [MyApp]
        var activeId: UUID
        var memoryThreads: [ChatThread]
        var memoryCurrentThreadId: String
        var itemEventLog: ItemEventLog
        var fromDisk: Bool
    }

    private nonisolated static func load() -> Loaded {
        let dec = JSONDecoder()
        if let data = CloudDocument.read(indexURL),
           let index = try? dec.decode(IndexFile.self, from: data) {
            // Read app files in index order; tolerate missing/corrupt ones.
            let apps: [MyApp] = index.order.compactMap { id in
                CloudDocument.read(appURL(id)).flatMap { try? dec.decode(MyApp.self, from: $0) }
            }
            if !apps.isEmpty {
                let active = apps.contains(where: { $0.id == index.activeId }) ? index.activeId : apps[0].id
                var log = index.itemEventLog ?? ItemEventLog()
                log.prune()
                return Loaded(myApps: apps, activeId: active, memoryThreads: index.memoryThreads,
                              memoryCurrentThreadId: index.memoryCurrentThreadId,
                              itemEventLog: log, fromDisk: true)
            }
        }

        // Fresh install: seed just the Daily Briefing (default, active). The
        // guided tour offers to add a second example (Home Buying) at the end,
        // and every example is restorable from Settings. The caller writes this
        // to disk via `persist()`.
        let myApp = DailyBriefingExample.make()
        let firstThread = ChatThread()
        return Loaded(myApps: [myApp], activeId: myApp.id,
                      memoryThreads: [firstThread], memoryCurrentThreadId: firstThread.id,
                      itemEventLog: ItemEventLog(), fromDisk: false)
    }

    /// Reload all state from disk and republish. Called by the iCloud watcher
    /// when a remote edit lands so the UI reflects the other device.
    ///
    /// Before overwriting local state we (1) checkpoint any dirty in-memory
    /// MyApp that hasn't been persisted, and (2) capture + resolve any iCloud
    /// `NSFileVersion` conflicts — snapshotting every side so no offline edit
    /// is ever silently lost (issue #82).
    ///
    /// The heavy file IO — the whole-tree conflict scan and the coordinated
    /// reads of `index.json` + every app file — runs **off the main actor**
    /// (pupa#110): during an initial iCloud download the watcher fires this
    /// repeatedly, and doing that IO on main stampeded the UI thread. Only the
    /// in-memory dirty check (before) and the republish (after) touch main
    /// state. The watcher keeps `NSMetadataQuery` updates suppressed until this
    /// returns, so reloads can't overlap.
    public func reloadFromDisk() async {
        let enc = Self.stateEncoder()
        for app in myApps where (try? enc.encode(app))?.hashValue != lastAppHash[app.id] {
            SnapshotStore.record(app, reason: .preReload)
        }
        let loaded = await Task.detached(priority: .utility) { [self] in
            resolveConflictsCapturingSnapshots()
            return Self.load()
        }.value
        guard loaded.fromDisk else { return }
        myApps = loaded.myApps
        activeMyAppId = loaded.activeId
        memoryThreads = loaded.memoryThreads
        memoryCurrentThreadId = loaded.memoryCurrentThreadId
        itemEventLog = loaded.itemEventLog
        lastAppHash.removeAll()
        primeHashes()
    }

    // MARK: - Snapshot history

    /// Debounce a snapshot capture for `appId`, collapsing a burst of edits
    /// into one history entry.
    private func scheduleSnapshot(_ appId: UUID) {
        pendingSnapshotTasks[appId]?.cancel()
        pendingSnapshotTasks[appId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.captureSnapshot(appId, reason: .edit)
        }
    }

    private func captureSnapshot(_ appId: UUID, reason: SnapshotReason) {
        pendingSnapshotTasks[appId] = nil
        guard let app = myApps.first(where: { $0.id == appId }) else { return }
        SnapshotStore.record(app, reason: reason)
    }

    /// History entries for a MyApp, newest-first, for the History timeline.
    public func snapshots(forMyApp myAppId: UUID) -> [SnapshotMeta] {
        SnapshotStore.metas(myAppId)
    }

    /// Restore a MyApp to an earlier snapshot. Non-destructive / append-only
    /// (git-`revert`, not `git reset`): the current state is checkpointed
    /// first (so it stays recoverable), then the restored state is applied
    /// and recorded as the new head. Returns false if the snapshot can't be
    /// resolved.
    @discardableResult
    public func restore(myAppId: UUID, snapshotId: UUID) -> Bool {
        guard let idx = myApps.firstIndex(where: { $0.id == myAppId }),
              let restored = SnapshotStore.restoredApp(myAppId, id: snapshotId)
        else { return false }
        // Checkpoint the pre-restore state so the user can jump back to it,
        // then record the restored state as a strictly-newer head.
        let now = Date()
        SnapshotStore.record(myApps[idx], reason: .edit, now: now)
        myApps[idx] = restored
        SnapshotStore.record(restored, reason: .restored, now: now.addingTimeInterval(0.01))
        persist()
        emitItemEvent(myAppId: myAppId,
                      componentId: restored.activeComponentId ?? "",
                      kind: .restored, actor: .user)
        return true
    }

    /// Capture + resolve iCloud conflict versions for every app file. Each
    /// side (current + every unresolved `NSFileVersion`) is snapshotted; the
    /// live file is resolved to the newest side and lingering versions are
    /// marked resolved. `nonisolated` — pure file IO over statics, so
    /// `reloadFromDisk` can run it off the main actor.
    private nonisolated func resolveConflictsCapturingSnapshots() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.appsDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let versions = CloudDocument.conflictVersions(at: file)
            guard !versions.isEmpty else { continue }
            let liveData = CloudDocument.read(file)
            let liveDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let alternates: [(data: Data, date: Date)] = versions.compactMap { v in
                CloudDocument.readVersion(v).map { ($0, v.modificationDate ?? .distantPast) }
            }
            if let winner = captureConflict(
                liveData: liveData, liveDate: liveDate, versions: alternates) {
                try? CloudDocument.write(winner, to: file)
            }
            CloudDocument.resolveConflicts(at: file)
        }
    }

    /// Snapshot the live + every conflicting version of one app file and
    /// return the newest side's data. Pure over its inputs so the
    /// keep-both + newest-wins logic is unit-testable without `NSFileVersion`.
    /// `nonisolated` so `resolveConflictsCapturingSnapshots` stays off-main.
    nonisolated func captureConflict(
        liveData: Data?, liveDate: Date, versions: [(data: Data, date: Date)]
    ) -> Data? {
        let dec = JSONDecoder()
        if let liveData, let app = try? dec.decode(MyApp.self, from: liveData) {
            SnapshotStore.record(app, reason: .conflict)
        }
        var winner = liveData
        var winnerDate = liveDate
        for (data, date) in versions {
            if let app = try? dec.decode(MyApp.self, from: data) {
                SnapshotStore.record(app, reason: .conflict)
            }
            if date > winnerDate { winner = data; winnerDate = date }
        }
        return winner
    }

    #if DEBUG
    /// Test hook: capture the pending debounced snapshot immediately.
    func captureSnapshotNowForTesting(_ appId: UUID, reason: SnapshotReason = .edit) {
        captureSnapshot(appId, reason: reason)
    }
    #endif

    public static func clearStorage() {
        try? FileManager.default.removeItem(at: stateRoot)
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
