import Foundation

/// Rebuilds a `MyApp` from a `MyAppBundle` — the import half of the
/// marketplace. **The bundle is untrusted, attacker-controlled data.** It is
/// inert (no executable content), but is validated against an allow-list and
/// resource caps *before* anything touches the store or disk, then rebuilt in
/// dependency order. See `docs/marketplace.md` for the threat model.
@MainActor
public enum MyAppImporter {

    // MARK: Resource caps (DoS guards)

    static let maxBundleBytes = 8 * 1024 * 1024      // 8 MB raw, checked pre-decode
    static let maxComponents = 64
    static let maxItemsPerComponent = 5_000
    static let maxSlackMessagesPerChannel = 5_000
    static let maxMemoryFiles = 2_000
    static let maxMemoryFileBytes = 1 * 1024 * 1024  // 1 MB per memory file

    /// Settings keys that may survive import. **Security-critical**: keys like
    /// `shell_approval_disabled` must never be importable, so the dict is
    /// allow-listed down to the LLM override (itself re-validated below).
    static let allowedSettingKeys: Set<String> = [
        MyAppStore.llmProviderSettingsKey,
        MyAppStore.llmModelSettingsKey,
    ]

    // MARK: Errors

    public enum ImportError: LocalizedError {
        case tooLarge(bytes: Int)
        case notABundle
        case newerFormat(found: Int, supported: Int)
        case unknownType(String)
        case unsupportedKind(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "This file is too large to import (\(bytes / (1024 * 1024)) MB)."
            case .notABundle:
                return "This file isn't a valid Pupa app bundle."
            case .newerFormat(let found, let supported):
                return "This bundle was exported by a newer version of Pupa "
                    + "(format \(found) > \(supported)). Update Pupa to import it."
            case .unknownType(let id):
                return "Unknown app type '\(id)'."
            case .unsupportedKind(let kind):
                return "Unsupported component '\(kind)'."
            case .malformed(let why):
                return "This bundle is malformed: \(why)."
            }
        }
    }

    public struct ImportResult {
        public let myAppId: UUID
        /// Non-fatal notes surfaced to the user (newer app version, dropped
        /// settings, dropped LLM overrides). Empty = clean import.
        public let warnings: [String]
    }

    // MARK: Entry point

    @discardableResult
    public static func importBundle(
        _ data: Data,
        into store: MyAppStore,
        memory: MemoryStore
    ) throws -> ImportResult {
        var warnings: [String] = []

        // Stage 0a — size cap before decode.
        guard data.count <= maxBundleBytes else { throw ImportError.tooLarge(bytes: data.count) }

        // Stage 0b — decode + header (read & validated first).
        let bundle: MyAppBundle
        do {
            bundle = try MyAppBundle.makeDecoder().decode(MyAppBundle.self, from: data)
        } catch {
            throw ImportError.notABundle
        }
        guard bundle.header.format == MyAppBundle.formatMagic else { throw ImportError.notABundle }
        guard bundle.header.formatVersion <= MyAppBundle.currentFormatVersion else {
            throw ImportError.newerFormat(found: bundle.header.formatVersion,
                                          supported: MyAppBundle.currentFormatVersion)
        }
        if isNewer(bundle.header.appVersion, than: PupaAppVersion) {
            warnings.append("Exported by a newer version of Pupa (\(bundle.header.appVersion)); "
                + "some content may not load.")
        }

        let decoded = bundle.app

        // Stage 0c — type + component kinds.
        guard let type = MyAppTypeRegistry.shared.resolve(id: decoded.typeId) else {
            throw ImportError.unknownType(decoded.typeId)
        }
        guard !decoded.components.isEmpty else { throw ImportError.malformed("no components") }
        guard decoded.components.count <= maxComponents else {
            throw ImportError.malformed("too many components")
        }
        for comp in decoded.components {
            let kind = comp.kindString
            if kind == "empty" { continue }
            guard type.supportedComponentKinds.contains(kind),
                  ComponentExportRegistry.shared.isRegistered(forKind: kind) else {
                throw ImportError.unsupportedKind(kind)
            }
        }

        // Stage 0d — uniqueness + per-component caps.
        var seenComponentIds: Set<String> = []
        var seenItemIds: Set<UUID> = []
        for comp in decoded.components {
            guard seenComponentIds.insert(comp.id).inserted else {
                throw ImportError.malformed("duplicate component id '\(comp.id)'")
            }
            try validateBody(comp.body, seenItemIds: &seenItemIds)
        }

        // Stage 0e — settings allow-list (drops security-relevant keys).
        let (cleanSettings, droppedKeys) = sanitizeSettings(decoded.settings)
        if !droppedKeys.isEmpty {
            warnings.append("Ignored unsupported settings: \(droppedKeys.sorted().joined(separator: ", ")).")
        }

        // Stage 1–3 operate on a local component array, then we build the app.
        var components = decoded.components
        let keptIds = Set(components.map(\.id))
        let validRefs = components.presentItemRefs()

        // Stage 2 — prune dangling refs (no dropped components on import, but
        // a hostile bundle may still carry refs to absent items/components).
        for i in components.indices {
            components[i].body.remapReferences(
                keepComponent: { keptIds.contains($0) },
                keepItem: { validRefs.contains($0) })
        }

        // Stage 3 — drop per-agent LLM overrides not in the catalog.
        sanitizeAgentLLM(&components, warnings: &warnings)

        // Resolve focused component.
        var activeId = decoded.activeComponentId
        if let a = activeId, !keptIds.contains(a) { activeId = components.first?.id }

        // Stage 0f — fresh id, unique name (+slug), fresh thread & timestamp.
        let newName = uniqueName(base: decoded.name, store: store)
        let fresh = ChatThread()
        let app = MyApp(
            id: UUID(),
            name: newName,
            iconSystemName: decoded.iconSystemName,
            typeId: decoded.typeId,
            components: components,
            activeComponentId: activeId,
            threads: [fresh],
            currentThreadId: fresh.id,
            createdAt: Date(),
            settings: cleanSettings)

        // Stage 4 — insert.
        let id = store.importMyApp(app)

        // Stage 5 — memories (last). Re-rooted under the new name; every write
        // goes through `MemoryStore.writeFile`, whose `resolve` blocks `..`,
        // absolute paths and non-`.md` files.
        writeMemories(bundle.memories, appName: newName, memory: memory)

        return ImportResult(myAppId: id, warnings: warnings)
    }

    // MARK: - Validation helpers

    private static func validateBody(_ body: CanvasApp, seenItemIds: inout Set<UUID>) throws {
        func note(_ id: UUID) throws {
            guard seenItemIds.insert(id).inserted else {
                throw ImportError.malformed("duplicate item id")
            }
        }
        switch body {
        case .tracker(let t):
            guard t.items.count <= maxItemsPerComponent else { throw ImportError.malformed("too many tracker rows") }
            for it in t.items { try note(it.id) }
        case .calendar(let cal):
            guard cal.events.count <= maxItemsPerComponent else { throw ImportError.malformed("too many events") }
            for e in cal.events { try note(e.id) }
        case .checklist(let cl):
            guard cl.items.count <= maxItemsPerComponent else { throw ImportError.malformed("too many checklist items") }
            for it in cl.items { try note(it.id) }
        case .slack(let s):
            for (_, msgs) in s.messagesByChannel {
                guard msgs.count <= maxSlackMessagesPerChannel else { throw ImportError.malformed("too many messages") }
            }
            // Agent / channel ids unique within this component.
            var agentIds: Set<String> = []
            for a in s.agents where !agentIds.insert(a.id).inserted {
                throw ImportError.malformed("duplicate slack agent id")
            }
            var channelIds: Set<String> = []
            for c in s.channels where !channelIds.insert(c.id).inserted {
                throw ImportError.malformed("duplicate slack channel id")
            }
        case .calculator, .chart, .empty:
            break
        }
    }

    /// Keep only allow-listed settings; re-validate the LLM pair against the
    /// catalog (drop both if the pair is unknown). Returns the dropped keys.
    private static func sanitizeSettings(
        _ raw: [String: SettingValue]
    ) -> (clean: [String: SettingValue], dropped: [String]) {
        var clean: [String: SettingValue] = [:]
        var dropped: [String] = []
        for (k, v) in raw {
            if allowedSettingKeys.contains(k) { clean[k] = v } else { dropped.append(k) }
        }
        if case .string(let provider)? = clean[MyAppStore.llmProviderSettingsKey],
           case .string(let model)? = clean[MyAppStore.llmModelSettingsKey],
           KnownLLMModelCatalog.model(provider: provider, modelId: model) != nil {
            // Valid pair — keep.
        } else {
            clean[MyAppStore.llmProviderSettingsKey] = nil
            clean[MyAppStore.llmModelSettingsKey] = nil
        }
        return (clean, dropped)
    }

    private static func sanitizeAgentLLM(_ components: inout [Component], warnings: inout [String]) {
        var droppedAny = false
        for i in components.indices {
            guard case .slack(var s) = components[i].body else { continue }
            var changed = false
            for a in s.agents.indices {
                let p = s.agents[a].llmProvider
                let m = s.agents[a].llmModel
                let valid = (p != nil && m != nil) && KnownLLMModelCatalog.model(provider: p!, modelId: m!) != nil
                if !valid && (p != nil || m != nil) {
                    s.agents[a].llmProvider = nil
                    s.agents[a].llmModel = nil
                    changed = true
                    droppedAny = true
                }
            }
            if changed { components[i].body = .slack(s) }
        }
        if droppedAny {
            warnings.append("Some agent model overrides weren't available and fell back to the default.")
        }
    }

    /// First free name whose display name *and* memory slug don't collide with
    /// an existing app (slug collision would clobber another app's memories).
    private static func uniqueName(base: String, store: MyAppStore) -> String {
        let names = Set(store.myApps.map(\.name))
        let slugs = Set(store.myApps.map { MemoryStore.myAppFolder(myAppName: $0.name) })
        func free(_ candidate: String) -> Bool {
            !names.contains(candidate) && !slugs.contains(MemoryStore.myAppFolder(myAppName: candidate))
        }
        if free(base) { return base }
        var n = 2
        while !free("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private static func writeMemories(_ files: [MemoryFile], appName: String, memory: MemoryStore) {
        let capped = files.prefix(maxMemoryFiles)
        let scoped = memory.appScopedStore(forAppNamed: appName)
        for file in capped {
            guard file.content.utf8.count <= maxMemoryFileBytes else { continue }
            // writeFile's resolve() rejects `..`, absolute paths and non-.md;
            // a hostile path simply fails to write rather than escaping.
            try? scoped.writeFile(path: file.path, content: file.content)
        }
    }

    /// Compare dotted numeric versions ("0.0.103"). Returns true when `lhs`
    /// is strictly newer than `rhs`. Non-numeric components compare as 0.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
