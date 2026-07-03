import Foundation

/// Item refs (`componentId` + `itemId`) actually present in a component list —
/// the link *targets*. Shared by the exporter and importer to prune refs whose
/// target item no longer exists. Only link-bearing item kinds contribute.
extension Sequence where Element == Component {
    func presentItemRefs() -> Set<ComponentItemRef> {
        var refs: Set<ComponentItemRef> = []
        for comp in self {
            switch comp.body {
            case .tracker(let t):
                for it in t.items { refs.insert(ComponentItemRef(componentId: comp.id, itemId: it.id)) }
            case .calendar(let cal):
                for e in cal.events { refs.insert(ComponentItemRef(componentId: comp.id, itemId: e.id)) }
            case .checklist(let cl):
                for it in cl.items { refs.insert(ComponentItemRef(componentId: comp.id, itemId: it.id)) }
            case .slack, .calculator, .chart, .empty:
                break
            }
        }
        return refs
    }
}

/// Builds a `MyAppBundle` from a live `MyApp` — the export half of the
/// marketplace. Staged extraction (reverse of the import rebuild): select
/// components → strip records → prune dangling refs → carry agents → scope
/// memories → reset volatile state → assemble header.
@MainActor
public enum MyAppExporter {

    public struct Options {
        public var selectedComponentIds: Set<String>
        public var includeRecords: Bool
        public var includeMemories: Bool
        public init(selectedComponentIds: Set<String>, includeRecords: Bool, includeMemories: Bool) {
            self.selectedComponentIds = selectedComponentIds
            self.includeRecords = includeRecords
            self.includeMemories = includeMemories
        }
    }

    /// Assemble the bundle. `memory` is the *global* store; this re-scopes to
    /// the app's own memory root internally. `appVersion` stamps the header.
    public static func makeBundle(
        app: MyApp,
        options: Options,
        memory: MemoryStore,
        appVersion: String = PupaAppVersion
    ) -> MyAppBundle {
        var app = app
        let allKinds = Set(app.components.map(\.kindString))

        // 1. Components — keep only the selection (preserving order).
        app.components.removeAll { !options.selectedComponentIds.contains($0.id) }
        let keptIds = Set(app.components.map(\.id))

        // 2. Records — strip user rows per each kind's export policy.
        if !options.includeRecords {
            for i in app.components.indices {
                app.components[i].body = ComponentExportRegistry.shared.strippingUserData(app.components[i].body)
            }
        }

        // 3. Prune refs to dropped components and to stripped items (the valid
        //    targets are whatever survived steps 1–2).
        let validRefs = app.components.presentItemRefs()
        for i in app.components.indices {
            app.components[i].body.remapReferences(
                keepComponent: { keptIds.contains($0) },
                keepItem: { validRefs.contains($0) })
        }

        // 4. Fix the focused component if it was dropped.
        if let active = app.activeComponentId, !keptIds.contains(active) {
            app.activeComponentId = app.components.first?.id
        }

        // 5. Agents are structural in the tree — carried as-is.

        // 6. Memories — scope to the app's root; filter by the toggles.
        let selectedKinds = Set(app.components.map(\.kindString))
        let droppedKinds = allKinds.subtracting(selectedKinds)
        let scoped = memory.appScopedStore(forAppNamed: app.name)
        let memories = scoped.exportFiles { path in
            // Drop a deselected component kind's whole subtree (e.g. `slack/`).
            if let top = path.split(separator: "/").first.map(String.init),
               droppedKinds.contains(top) { return false }
            // Memories off ⇒ keep the whole `pupa/` config subtree (agent +
            // subagent prompts, skills, SETUP) — that's app capability, not
            // user data. Everything else (user notes, records) is dropped.
            if !options.includeMemories {
                return path.hasPrefix("pupa/")
            }
            return true
        }

        // 7. Reset volatile, backend-bound state.
        let fresh = ChatThread()
        app.threads = [fresh]
        app.currentThreadId = fresh.id

        let header = MyAppBundle.Header(
            appVersion: appVersion,
            includedRecords: options.includeRecords,
            includedMemories: options.includeMemories)
        return MyAppBundle(header: header, app: app, memories: memories)
    }

    /// Bundle *every* given app into one `MyAppLibraryBundle` — the multi-app
    /// export. Each app is exported whole (all components selected) with the
    /// shared record/memory toggles, reusing `makeBundle`; no new per-app logic.
    public static func makeLibraryBundle(
        apps: [MyApp],
        includeRecords: Bool,
        includeMemories: Bool,
        memory: MemoryStore,
        appVersion: String = PupaAppVersion
    ) -> MyAppLibraryBundle {
        let bundles = apps.map { app in
            makeBundle(
                app: app,
                options: .init(
                    selectedComponentIds: Set(app.components.map(\.id)),
                    includeRecords: includeRecords,
                    includeMemories: includeMemories),
                memory: memory,
                appVersion: appVersion)
        }
        let header = MyAppLibraryBundle.Header(
            appVersion: appVersion,
            appCount: bundles.count,
            includedRecords: includeRecords,
            includedMemories: includeMemories)
        return MyAppLibraryBundle(header: header, apps: bundles)
    }
}
