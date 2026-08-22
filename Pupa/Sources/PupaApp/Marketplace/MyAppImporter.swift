import Foundation

/// Rebuilds a `MyApp` from a `MyAppBundle` — the import half of the
/// marketplace. **The bundle is untrusted, attacker-controlled data.** It is
/// inert (no executable content), but is validated against an allow-list and
/// resource caps *before* anything touches the store or disk, then rebuilt in
/// dependency order. See `docs/marketplace.md` for the threat model.
@MainActor
public enum MyAppImporter {

    // MARK: Resource caps (DoS guards)

    // `nonisolated` so the same cap can bound a download off the main actor
    // (`MarketplaceInstallLink.fetchBundle`) — one number, both entry points.
    nonisolated static let maxBundleBytes = 64 * 1024 * 1024  // 64 MB raw, checked pre-decode
    static let maxLibraryBytes = 256 * 1024 * 1024   // 256 MB aggregate for a library
    static let maxAppsPerLibrary = 128
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

    /// Result of importing a multi-app library: the ids that landed plus any
    /// per-app warnings (including apps skipped best-effort).
    public struct LibraryImportResult {
        public let myAppIds: [UUID]
        public let warnings: [String]
    }

    /// Which `.pupa` payload a file holds — a single app or a library. Both
    /// share the extension and are told apart by the `header.format` magic.
    public enum BundleFormat {
        case single
        case library
        case unknown
    }

    /// Peek at the `header.format` magic without full validation, so the UI can
    /// route to the right importer (and build the right confirm preview).
    public static func probeFormat(_ data: Data) -> BundleFormat {
        struct Probe: Decodable { struct H: Decodable { let format: String }; let header: H }
        guard data.count <= maxLibraryBytes,
              let probe = try? MyAppBundle.makeDecoder().decode(Probe.self, from: data) else {
            return .unknown
        }
        switch probe.header.format {
        case MyAppBundle.formatMagic: return .single
        case MyAppLibraryBundle.formatMagic: return .library
        default: return .unknown
        }
    }

    // MARK: Entry point

    @discardableResult
    public static func importBundle(
        _ data: Data,
        into store: MyAppStore,
        memory: MemoryStore
    ) throws -> ImportResult {
        // Stage 0a — size cap before decode.
        guard data.count <= maxBundleBytes else { throw ImportError.tooLarge(bytes: data.count) }

        // Stage 0b — decode (header validated inside `importDecoded`).
        let bundle: MyAppBundle
        do {
            bundle = try MyAppBundle.makeDecoder().decode(MyAppBundle.self, from: data)
        } catch {
            throw ImportError.notABundle
        }
        return try importDecoded(bundle, into: store, memory: memory)
    }

    /// Import an already-decoded bundle — the shared validation authority for
    /// both the single-app path and each app inside a library. **The bundle is
    /// untrusted:** validated against an allow-list and caps before any store /
    /// disk mutation.
    @discardableResult
    static func importDecoded(
        _ bundle: MyAppBundle,
        into store: MyAppStore,
        memory: MemoryStore
    ) throws -> ImportResult {
        var warnings: [String] = []

        // Header (read & validated first).
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
        var (cleanSettings, droppedKeys) = sanitizeSettings(decoded.settings)
        if !droppedKeys.isEmpty {
            warnings.append("Ignored unsupported settings: \(droppedKeys.sorted().joined(separator: ", ")).")
        }
        // Imported content doesn't get to reach the network unprompted. Card
        // and markdown images are fetched on render, with no tap, so a bundle
        // could otherwise beacon (and probe the LAN — ATS permits local
        // networking) the moment its app is opened. Set *after* the allow-list,
        // which has already dropped any value the bundle tried to supply, so a
        // bundle can't grant itself this.
        cleanSettings[MyAppStore.remoteImagesSettingsKey] = .bool(false)

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

        // Resolve focused component.
        var activeId = decoded.activeComponentId
        if let a = activeId, !keptIds.contains(a) { activeId = components.first?.id }

        // Stage 0f — fresh id, unique name, fresh thread & timestamp.
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

        // Stage 5 — memories (last). Re-rooted under the new app's immutable id
        // (fresh UUID above) — so a re-import can never collide with or clobber
        // the source app's memory subtree. Every write goes through
        // `MemoryStore.writeFile`, whose `resolve` blocks `..`, absolute paths and
        // any extension outside the `.md` / `.json` allowlist.
        warnings += writeMemories(bundle.memories, appId: id, memory: memory)

        return ImportResult(myAppId: id, warnings: warnings)
    }

    /// Import a multi-app `MyAppLibraryBundle`. **Best-effort:** each app runs
    /// through the same per-app authority (`importDecoded`); one malformed app
    /// is skipped with a warning rather than sinking the whole library. Because
    /// each app is inserted before the next is imported, the slug-unique rename
    /// naturally deduplicates apps that collide with each other.
    @discardableResult
    public static func importLibrary(
        _ data: Data,
        into store: MyAppStore,
        memory: MemoryStore
    ) throws -> LibraryImportResult {
        // Size cap before decode.
        guard data.count <= maxLibraryBytes else { throw ImportError.tooLarge(bytes: data.count) }

        // Decode + header (magic + version).
        let library: MyAppLibraryBundle
        do {
            library = try MyAppBundle.makeDecoder().decode(MyAppLibraryBundle.self, from: data)
        } catch {
            throw ImportError.notABundle
        }
        guard library.header.format == MyAppLibraryBundle.formatMagic else { throw ImportError.notABundle }
        guard library.header.formatVersion <= MyAppLibraryBundle.currentFormatVersion else {
            throw ImportError.newerFormat(found: library.header.formatVersion,
                                          supported: MyAppLibraryBundle.currentFormatVersion)
        }
        guard library.apps.count <= maxAppsPerLibrary else {
            throw ImportError.malformed("too many apps")
        }

        var ids: [UUID] = []
        var warnings: [String] = []
        for appBundle in library.apps {
            do {
                let result = try importDecoded(appBundle, into: store, memory: memory)
                ids.append(result.myAppId)
                warnings.append(contentsOf: result.warnings)
            } catch {
                warnings.append("Skipped '\(appBundle.app.name)': \(error.localizedDescription)")
            }
        }
        return LibraryImportResult(myAppIds: ids, warnings: warnings)
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
            // Channel ids unique within this component. (Agents are filesystem
            // subagents — validated as memory files, not here.)
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
        // The model catalog is now backend-provided (per-harness discovery), so
        // we can't validate the pair against a static list here. Keep it if both
        // fields are non-empty strings; an unknown pair is rejected by the
        // backend at request time with a clear error toast.
        if case .string(let provider)? = clean[MyAppStore.llmProviderSettingsKey],
           case .string(let model)? = clean[MyAppStore.llmModelSettingsKey],
           !provider.isEmpty, !model.isEmpty {
            // Plausible pair — keep.
        } else {
            clean[MyAppStore.llmProviderSettingsKey] = nil
            clean[MyAppStore.llmModelSettingsKey] = nil
        }
        return (clean, dropped)
    }

    /// First display name that doesn't collide with an existing app. Memory
    /// folders are keyed on the app's uuid, so only the visible name can clash.
    private static func uniqueName(base: String, store: MyAppStore) -> String {
        let names = Set(store.myApps.map(\.name))
        func free(_ candidate: String) -> Bool { !names.contains(candidate) }
        if free(base) { return base }
        var n = 2
        while !free("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Force `confirm: true` on every rule in imported automation text.
    ///
    /// `confirm: false` starts a chat turn with no bubble
    /// (`RuleEngine.pendingAutoFire`) — from a bundle, that's someone else's
    /// prompt reaching the model with the user's tools. Rewrites the JSON so
    /// the file on disk *is* the enforced truth and nothing downstream has to
    /// track provenance. Nil when unreadable: unparseable rules aren't written.
    /// See `docs/marketplace.md`.
    static func sanitizeAutomations(_ content: String) -> String? {
        guard let data = content.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let automations = root["automations"] as? [String: Any] else { return nil }

        var cleaned: [String: Any] = [:]
        for (event, value) in automations {
            guard let entries = value as? [[String: Any]] else {
                cleaned[event] = value   // not rule-shaped; the parser drops it
                continue
            }
            cleaned[event] = entries.map { entry -> [String: Any] in
                var copy = entry
                copy["confirm"] = true
                return copy
            }
        }
        root["automations"] = cleaned

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8) else { return nil }
        return text
    }

    /// Whether a bundle path lands on the automation rules file.
    ///
    /// Canonicalised by `MemoryStore` — the same function that decides where
    /// the file is written — so the two can't disagree. They did: this used to
    /// strip one leading `./` and compare, while the store also strips leading
    /// slashes, collapses empty components and folds `..`, so
    /// `/pupa/automations.json` landed on the rules file while this said it
    /// hadn't. Case-insensitive because the filesystem is.
    static func isAutomationsPath(_ path: String) -> Bool {
        MemoryStore.canonicalise(path)
            .caseInsensitiveCompare(MemoryStore.pupaAutomationsPath) == .orderedSame
    }

    /// Returns any user-facing warnings (an unreadable rules file is dropped,
    /// and silently losing a bundle's automations would look like a bug).
    private static func writeMemories(
        _ files: [MemoryFile], appId: UUID, memory: MemoryStore
    ) -> [String] {
        var warnings: [String] = []
        let capped = files.prefix(maxMemoryFiles)
        let scoped = memory.appScopedStore(forAppId: appId)
        for file in capped {
            guard file.content.utf8.count <= maxMemoryFileBytes else { continue }
            var content = file.content
            if isAutomationsPath(file.path) {
                guard let safe = sanitizeAutomations(content) else {
                    warnings.append("Couldn't read this app's automation rules, so they were skipped.")
                    continue
                }
                content = safe
            }
            // writeFile's resolve() rejects `..`, absolute paths and any
            // extension outside the `.md` / `.json` allowlist; a hostile path
            // simply fails to write rather than escaping.
            _ = try? scoped.writeFile(path: file.path, content: content)
        }
        return warnings
    }

    /// Compare dotted numeric versions ("0.0.103"). Returns true when `lhs`
    /// is strictly newer than `rhs`. Non-numeric components compare as 0.
    nonisolated static func isNewer(_ lhs: String, than rhs: String) -> Bool {
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
