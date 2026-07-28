import Foundation
import Observation

/// Sandboxed markdown filesystem backing the user's persistent memories.
///
/// The memories folder lives on disk at
/// `~/Library/Application Support/pupa/memories/`. `tree` is rebuilt
/// from disk after every mutation so SwiftUI views observing the
/// `MemoryStore` instance refresh as the agent writes files.
///
/// Path discipline: all callers pass *relative* POSIX-ish paths
/// (e.g. `"notes/diet.md"`). The root is forbidden as a write target. Paths
/// containing `..`, leading `/`, or non-normalised segments are rejected.
@MainActor
@Observable
public final class MemoryStore {
    /// Root folder. Children are sorted: folders first, then files, both alphabetised.
    public private(set) var tree: MemoryNode

    private let root: URL

    /// Consulted before every mutating call with the target path (relative to
    /// this store's root). Returning `true` throws `MemoryError.locked`; reads
    /// stay open. Scoped app stores ignore the path and return their MyApp's
    /// `isMemoryLocked`; the global (sidebar) store maps the leading path
    /// segment to a MyApp. Nil (the default) leaves the store fully writable.
    public var writeGuard: ((String) -> Bool)?

    public init(rootOverride: URL? = nil) {
        self.root = rootOverride ?? Self.defaultRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.tree = Self.scan(root: root)
    }

    // MARK: - Public filesystem API

    /// Backstop for every mutating op — throws when `path` is locked.
    private func ensureWritable(_ path: String) throws {
        if writeGuard?(normalise(path)) == true { throw MemoryError.locked }
    }

    public func ls(path: String = "", recursive: Bool = false) throws -> [Entry] {
        let url = try resolve(path, requireExists: true)
        guard isDirectory(url) else {
            throw MemoryError.notADirectory(path)
        }
        if recursive {
            return collectRecursive(at: url, relativeTo: url, prefix: normalise(path))
        }
        return try shallowEntries(at: url, prefix: normalise(path))
    }

    public func readFile(path: String, offset: Int? = nil, limit: Int? = nil) throws -> ReadResult {
        let url = try resolve(path, requireExists: true)
        guard !isDirectory(url) else { throw MemoryError.notAFile(path) }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let total = lines.count
        let start = max(0, offset ?? 0)
        let end = min(total, start + (limit ?? total))
        guard start <= end else {
            return ReadResult(content: "", totalLines: total, offset: start, returnedLines: 0)
        }
        let slice = lines[start..<end].joined(separator: "\n")
        return ReadResult(content: slice, totalLines: total, offset: start, returnedLines: end - start)
    }

    @discardableResult
    public func writeFile(path: String, content: String) throws -> Int {
        try ensureWritable(path)
        let url = try resolve(path, requireExists: false, mustBeFile: true)
        try ensureParent(of: url)
        try CloudDocument.write(content.data(using: .utf8)!, to: url)
        rescan()
        return content.utf8.count
    }

    @discardableResult
    public func appendFile(path: String, content: String) throws -> Int {
        try ensureWritable(path)
        let url = try resolve(path, requireExists: false, mustBeFile: true)
        try ensureParent(of: url)
        // Coordinated read-modify-write so appends are iCloud-safe.
        let existing = CloudDocument.read(url) ?? Data()
        try CloudDocument.write(existing + (content.data(using: .utf8) ?? Data()), to: url)
        rescan()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? content.utf8.count
    }

    /// sed-style surgical edit. Matches Claude Code's Edit tool contract:
    /// `oldString` must occur exactly once unless `replaceAll` is true.
    /// Returns the number of replacements made.
    @discardableResult
    public func editFile(
        path: String,
        oldString: String,
        newString: String,
        replaceAll: Bool = false
    ) throws -> Int {
        try ensureWritable(path)
        guard !oldString.isEmpty else { throw MemoryError.invalidEdit("oldString is empty") }
        guard oldString != newString else { throw MemoryError.invalidEdit("oldString == newString") }
        let url = try resolve(path, requireExists: true, mustBeFile: true)
        let original: String
        if let data = CloudDocument.read(url), let text = String(data: data, encoding: .utf8) {
            original = text
        } else {
            original = try String(contentsOf: url, encoding: .utf8)
        }
        let occurrences = countOccurrences(of: oldString, in: original)
        guard occurrences > 0 else { throw MemoryError.editNotFound(path) }
        if !replaceAll && occurrences > 1 {
            throw MemoryError.editNotUnique(path, occurrences: occurrences)
        }
        let updated: String
        let replacements: Int
        if replaceAll {
            updated = original.replacingOccurrences(of: oldString, with: newString)
            replacements = occurrences
        } else {
            if let range = original.range(of: oldString) {
                updated = original.replacingCharacters(in: range, with: newString)
            } else {
                throw MemoryError.editNotFound(path)
            }
            replacements = 1
        }
        try CloudDocument.write(updated.data(using: .utf8)!, to: url)
        rescan()
        return replacements
    }

    public func grep(
        pattern: String,
        path: String = "",
        glob: String? = nil,
        ignoreCase: Bool = false,
        contextLines: Int = 0,
        maxHits: Int = 50
    ) throws -> [GrepHit] {
        let url = try resolve(path, requireExists: true)
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        var hits: [GrepHit] = []
        let globMatcher = glob.flatMap(GlobMatcher.init)
        let iterator: [URL] = isDirectory(url)
            ? filesUnder(url)
            : [url]
        for fileURL in iterator {
            let relative = relativePath(of: fileURL)
            if let globMatcher, !globMatcher.matches(relative) { continue }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    let ctxStart = max(0, idx - contextLines)
                    let ctxEnd = min(lines.count - 1, idx + contextLines)
                    let context = contextLines == 0 ? line : lines[ctxStart...ctxEnd].joined(separator: "\n")
                    hits.append(GrepHit(path: relative, line: idx + 1, text: context))
                    if hits.count >= maxHits { return hits }
                }
            }
        }
        return hits
    }

    public func move(from: String, to: String) throws {
        try ensureWritable(from)   // block moving out of a locked subtree
        try ensureWritable(to)     // …and moving into one
        let src = try resolve(from, requireExists: true)
        let dst = try resolve(to, requireExists: false)
        try CloudDocument.move(from: src, to: dst)
        rescan()
    }

    public func delete(path: String, recursive: Bool = false) throws {
        try ensureWritable(path)
        let url = try resolve(path, requireExists: true)
        guard url != root else { throw MemoryError.cannotModifyRoot }
        if isDirectory(url) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if !contents.isEmpty && !recursive {
                throw MemoryError.folderNotEmpty(path)
            }
        }
        CloudDocument.delete(url)
        rescan()
    }

    public func createFolder(path: String) throws {
        try ensureWritable(path)
        let url = try resolve(path, requireExists: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rescan()
    }

    /// Whether a file exists at `path` (relative to the memories root).
    /// Returns `false` for folders, missing entries, or invalid paths — never
    /// throws. Used by the sidebar sheets to detect collisions before writing.
    public func fileExists(at path: String) -> Bool {
        guard let url = try? resolve(path, requireExists: false) else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    /// Whether a folder exists at `path`. The root itself counts.
    public func folderExists(at path: String) -> Bool {
        guard let url = try? resolve(path, requireExists: false) else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Flat list of every file path under the root, used as the per-turn
    /// memories snapshot the agent sees.
    public func snapshotPaths() -> [String] {
        var out: [String] = []
        for file in filesUnder(root) {
            out.append(relativePath(of: file))
        }
        return out.sorted()
    }

    /// Snapshot every file under the root as `(relativePath, content)` pairs —
    /// the marketplace export of this (app-scoped) memory store. Paths are
    /// root-relative so import can re-root them under a new app's slug.
    /// Optionally restrict to a set of relative paths (e.g. only `AGENTS.md`).
    /// Reads are coordinated so iCloud-synced files export their latest bytes.
    public func exportFiles(matching keep: ((String) -> Bool)? = nil) -> [MemoryFile] {
        snapshotPaths().compactMap { path in
            if let keep, !keep(path) { return nil }
            guard let url = try? resolve(path, requireExists: true),
                  let data = CloudDocument.read(url),
                  let content = String(data: data, encoding: .utf8) else { return nil }
            return MemoryFile(path: path, content: content)
        }
    }

    // MARK: - Private

    /// Memories live under the active storage root (iCloud container when
    /// available, else local Application Support) — see `PupaStorage`.
    private static func defaultRoot() -> URL {
        PupaStorage.memoriesRoot
    }

    // MARK: - Path helpers for structured namespace

    /// File extensions the agent may write. Config is JSON-shaped; everything
    /// else stays markdown. Executable/free-format types are intentionally
    /// excluded (marketplace import threat surface; nothing executes them).
    static let writableExtensions: Set<String> = ["md", "json"]

    /// Top-level folder for a myApp: `<slug>` (e.g. `"my-fitness-app"`).
    public nonisolated static func myAppFolder(myAppName: String) -> String {
        slugify(myAppName)
    }

    // MARK: `pupa/` config folder
    //
    // Each scope (myApp or orchestrator) keeps its driving prompts + skills in
    // a visible `pupa/` subfolder, separate from user content at the root.
    // The constants below are *relative* to a scope-rooted `MemoryStore`.

    /// The config folder name. Visible (non-dot) so it rides the memory tree,
    /// sidebar, glob, and the marketplace bundle unchanged.
    public static let pupaFolderName = "pupa"
    /// Main agent prompt, relative to a scope-rooted store.
    public static let pupaAgentsPath = "pupa/AGENTS.md"
    /// Skills directory, relative to a scope-rooted store: `pupa/skills`.
    public static let pupaSkillsDir = "pupa/skills"
    /// Bundle-scoped automation rules, relative to a scope-rooted store:
    /// `pupa/automations.json`. Rides the memory subtree + `.pupa` bundle
    /// unchanged (`.json` is importer-allowed). See `AutomationStore`.
    public static let pupaAutomationsPath = "pupa/automations.json"
    /// Plugins directory, relative to a scope-rooted store: `pupa/plugins`.
    /// A plugin bundles managed skills at `pupa/plugins/<id>/skills/<name>/SKILL.md`,
    /// keeping them out of the user's `pupa/skills/` space.
    public nonisolated static let pupaPluginsDir = "pupa/plugins"
    /// Subagents directory, relative to a scope-rooted store: `pupa/agents`.
    /// Each subagent is `pupa/agents/<slug>/AGENTS.md` + a private notes subtree.
    public static let pupaAgentsDir = "pupa/agents"
    /// Relative path for a named subagent's folder: `pupa/agents/<slug>`.
    public static func subagentSubfolder(name: String) -> String {
        "\(pupaAgentsDir)/\(slugify(name))"
    }
    /// Absolute (global-root-relative) `pupa/` folder for a myApp.
    public static func pupaFolder(myAppName: String) -> String {
        "\(myAppFolder(myAppName: myAppName))/\(pupaFolderName)"
    }

    /// Top-level folder for the orchestrator's memories.
    public nonisolated static func orchestratorFolder() -> String { "orchestrator" }

    /// Absolute URL for a myApp's memory root — used as `rootOverride` when
    /// creating a session-scoped `MemoryStore`.
    public static func appRoot(myAppName: String) -> URL {
        defaultRoot().appendingPathComponent(myAppFolder(myAppName: myAppName), isDirectory: true)
    }

    /// This store's root URL (the override, or the default `…/memories`).
    public var rootURL: URL { root }

    /// A store scoped to one myApp's folder *under this store's root* — so a
    /// store with a test `rootOverride` produces a child under the same temp
    /// dir rather than the real Application Support default. Used by the
    /// marketplace export/import. Writes through the child rescan this store
    /// too, so the sidebar/Memories tab refresh without a relaunch.
    public func appScopedStore(forAppNamed name: String) -> MemoryStore {
        let child = MemoryStore(rootOverride: root.appendingPathComponent(
            Self.myAppFolder(myAppName: name), isDirectory: true))
        child.onDidMutate = { [weak self] in self?.rescan() }
        return child
    }

    /// Move a myApp's memory subtree to its new slug after a rename. Memories
    /// are keyed on the display-name slug, so without this the Memories tab,
    /// export scoping, and future agent writes all resolve to an empty new
    /// slug while the files sit orphaned under the old one.
    ///
    /// No-op when the slugs coincide or the source folder is missing. If the
    /// destination folder already exists the trees merge per-file and an
    /// existing destination file wins (the source copy stays put).
    public func migrateAppFolder(fromAppNamed oldName: String, toAppNamed newName: String) {
        let oldSlug = Self.myAppFolder(myAppName: oldName)
        let newSlug = Self.myAppFolder(myAppName: newName)
        guard !oldSlug.isEmpty, !newSlug.isEmpty, oldSlug != newSlug else { return }
        let fm = FileManager.default
        let src = root.appendingPathComponent(oldSlug, isDirectory: true)
        let dst = root.appendingPathComponent(newSlug, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return }
        if !fm.fileExists(atPath: dst.path) {
            try? CloudDocument.move(from: src, to: dst)
        } else {
            let srcComponents = src.standardizedFileURL.pathComponents.count
            for file in filesUnder(src) {
                let rel = file.standardizedFileURL.pathComponents
                    .dropFirst(srcComponents).joined(separator: "/")
                let target = dst.appendingPathComponent(rel)
                guard !fm.fileExists(atPath: target.path) else { continue }
                try? CloudDocument.move(from: file, to: target)
            }
            if filesUnder(src).isEmpty { CloudDocument.delete(src) }
        }
        rescan()
    }

    /// Fold iCloud conflict-renamed twin dirs (`<base> N/`, space+digits —
    /// never valid slugify output) back into their base dir per-file,
    /// destination-wins. A differing twin copy is preserved under the sibling
    /// `conflicts/memories/<dest-rel>/<rel>/` tree (local-only). A twin whose
    /// cloud counterpart is still downloading is skipped (else adoption would
    /// miss files — retried on a later pass). Cloud-side twin files are removed
    /// by the mirror's normal baseline delete propagation on the next
    /// reconcile. Idempotent.
    ///
    /// **Top-level** twins (`memories/<slug> N`) fold when `<base>` is an
    /// addressable slug — top-level dirs are app slugs / orchestrator and
    /// slugify never emits a space, so the `<base> N` shape can only be an
    /// iCloud twin. **Nested** twins (`memories/<slug>/…/<x> N`) inside an
    /// addressable subtree fold only when a sibling `<x>` dir survives — the
    /// twin's origin — since agent-created nested dirs may legitimately contain
    /// spaces, so the name alone isn't proof.
    @discardableResult
    public func foldConflictTwinDirs(addressableBases: Set<String>) -> Bool {
        var changed = false
        // Top-level: gate on the addressable slug; no sibling required.
        for src in subdirs(root) where twinBase(src.lastPathComponent).map(addressableBases.contains) == true {
            changed = foldTwinDir(src) || changed
        }
        // Nested: recurse each addressable app subtree; require a surviving
        // sibling `<base>` dir before folding a `<base> N` twin.
        for base in addressableBases {
            changed = foldNestedTwins(under: root.appendingPathComponent(base, isDirectory: true)) || changed
        }
        if changed { rescan() }
        return changed
    }

    /// `<base> <digits>` → `base` (iCloud conflict-rename shape); nil otherwise.
    private func twinBase(_ name: String) -> String? {
        guard let space = name.lastIndex(of: " ") else { return nil }
        let digits = name[name.index(after: space)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(name[..<space])
    }

    /// Immediate subdirectories of `dir` (non-recursive).
    private func subdirs(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// Recursively fold nested `<base> N` twins that have a surviving sibling
    /// `<base>` dir. Bounded to `appRoot`'s subtree; non-twin dirs are descended.
    private func foldNestedTwins(under appRoot: URL) -> Bool {
        var changed = false
        for dir in subdirs(appRoot) {
            let sibling = dir.deletingLastPathComponent()
                .appendingPathComponent(twinBase(dir.lastPathComponent) ?? "", isDirectory: true)
            if twinBase(dir.lastPathComponent) != nil,
               (try? sibling.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                changed = foldTwinDir(dir) || changed
            } else {
                changed = foldNestedTwins(under: dir) || changed
            }
        }
        return changed
    }

    /// Fold one twin dir `src` (`<base> N`) into its sibling `<base>` dir,
    /// per file, destination-wins; differing copies quarantined. Skips (returns
    /// false) if the cloud twin is still materializing. Returns whether the
    /// local tree changed.
    @discardableResult
    private func foldTwinDir(_ src: URL) -> Bool {
        let fm = FileManager.default
        guard let base = twinBase(src.lastPathComponent) else { return false }
        // Cloud twin still materializing → folding now would strand its files.
        if let cloudTwin = PupaStorage.cloudMirrorRoot?
            .appendingPathComponent("memories/\(relToRoot(src))", isDirectory: true),
           fm.fileExists(atPath: cloudTwin.path),
           PupaStorage.kickUndownloaded(under: cloudTwin) > 0 { return false }
        let dst = src.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true)
        let destRel = relToRoot(dst)
        let srcComponents = src.standardizedFileURL.pathComponents.count
        var changed = false
        for file in filesUnder(src) {
            let rel = file.standardizedFileURL.pathComponents
                .dropFirst(srcComponents).joined(separator: "/")
            let target = dst.appendingPathComponent(rel)
            if !fm.fileExists(atPath: target.path) {
                try? CloudDocument.move(from: file, to: target)
            } else if CloudDocument.read(file) == CloudDocument.read(target) {
                CloudDocument.delete(file)
            } else {
                quarantineTwinCopy(file, destRel: destRel, rel: rel)
            }
            changed = true
        }
        if filesUnder(src).isEmpty {
            try? fm.removeItem(at: src)
            changed = true
        }
        return changed
    }

    /// `url`'s path relative to the store `root` (e.g. `jobhunting/companies/acme`).
    private func relToRoot(_ url: URL) -> String {
        url.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }

    /// Move a losing twin copy to `<root parent>/conflicts/memories/<dest-rel>/<rel>/<stamp>`
    /// — same layout as `StorageMirror`'s conflict preservation, local-only.
    private func quarantineTwinCopy(_ file: URL, destRel: String, rel: String) {
        let fm = FileManager.default
        let dir = root.deletingLastPathComponent()
            .appendingPathComponent("conflicts/memories/\(destRel)/\(rel)", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let ext = file.pathExtension
        let name = "\(stamp)-\(UUID().uuidString.prefix(4))" + (ext.isEmpty ? "" : ".\(ext)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.moveItem(at: file, to: dir.appendingPathComponent(name))
        StorageMirror.shared.scheduleReconcile()   // twin rel vanished locally
    }

    /// Absolute URL for the orchestrator's memory root.
    public static func orchestratorRoot() -> URL {
        defaultRoot().appendingPathComponent(orchestratorFolder(), isDirectory: true)
    }

    /// Component-type folder inside a myApp: `<myAppSlug>/<componentKind>`
    /// (e.g. `"my-fitness-app/slack"`).
    public static func componentFolder(myAppName: String, componentKind: String) -> String {
        "\(myAppFolder(myAppName: myAppName))/\(componentKind)"
    }

    /// Private subfolder for a named subagent within the global root:
    /// `<myAppSlug>/pupa/agents/<agentNameSlug>`
    /// (e.g. `"my-fitness-app/pupa/agents/marketing"`). Lives under the `pupa/`
    /// config folder so a subagent's prompt + private notes sit with the rest
    /// of the workspace config.
    public static func slackAgentFolder(myAppName: String, agentName: String) -> String {
        "\(myAppFolder(myAppName: myAppName))/\(slackAgentSubfolder(agentName: agentName))"
    }

    /// Relative path within an app-scoped `MemoryStore` for a named subagent:
    /// `pupa/agents/<agentNameSlug>` (e.g. `"pupa/agents/marketing"`).
    public static func slackAgentSubfolder(agentName: String) -> String {
        "pupa/agents/\(slugify(agentName))"
    }

    /// Lower-case alphanumerics + hyphens, no consecutive hyphens, capped at
    /// 60 characters. Mirrors `MemorySheets.slugify` without a SwiftUI import.
    nonisolated static func slugify(_ raw: String, maxLength: Int = 60) -> String {
        var out: [Character] = []
        var lastWasHyphen = false
        for scalar in raw.unicodeScalars {
            let c = Character(scalar)
            if scalar.properties.isAlphabetic || ("0"..."9").contains(c) {
                out.append(Character(c.lowercased()))
                lastWasHyphen = false
            } else if c == "-" || c == "_" || c.isWhitespace {
                if !lastWasHyphen && !out.isEmpty {
                    out.append("-")
                    lastWasHyphen = true
                }
            }
            if out.count >= maxLength { break }
        }
        while out.last == "-" { out.removeLast() }
        return String(out)
    }

    /// Called after every mutation so the global sidebar store stays in sync
    /// with writes made through a scoped (per-session) `MemoryStore` instance.
    var onDidMutate: (() -> Void)?

    func rescan() {
        tree = Self.scan(root: root)
        onDidMutate?()
    }

    /// Rebuild the tree from disk. Called by the iCloud watcher when remote
    /// edits land so the sidebar refreshes live. The disk walk runs off the
    /// main actor (pupa#110 — the watcher fires this repeatedly during an
    /// initial iCloud download); only the tree republish touches main state.
    public func reloadFromDisk() async {
        let root = self.root
        let rebuilt = await Task.detached(priority: .utility) { Self.scan(root: root) }.value
        tree = rebuilt
        onDidMutate?()
    }

    private nonisolated static func scan(root: URL) -> MemoryNode {
        let children = readChildren(at: root, prefix: "")
        return MemoryNode(name: "", path: "", kind: .folder, children: children)
    }

    private nonisolated static func readChildren(at url: URL, prefix: String) -> [MemoryNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        var folders: [MemoryNode] = []
        var files: [MemoryNode] = []
        for name in names where !name.hasPrefix(".") {
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
            let relPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if isDir.boolValue {
                folders.append(MemoryNode(
                    name: name,
                    path: relPath,
                    kind: .folder,
                    children: readChildren(at: child, prefix: relPath)
                ))
            } else {
                let size = (try? fm.attributesOfItem(atPath: child.path)[.size] as? Int) ?? 0
                files.append(MemoryNode(
                    name: name,
                    path: relPath,
                    kind: .file(sizeBytes: size),
                    children: nil
                ))
            }
        }
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return folders + files
    }

    private func relativePath(of url: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = url.standardizedFileURL.pathComponents
        guard childComponents.count > rootComponents.count,
              Array(childComponents.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func resolve(_ path: String, requireExists: Bool, mustBeFile: Bool = false) throws -> URL {
        let normalised = normalise(path)
        guard !normalised.isEmpty || !requireExists else {
            // Allow path="" to mean the root for ls / grep
            let exists = FileManager.default.fileExists(atPath: root.path)
            if !exists { throw MemoryError.notFound("") }
            return root
        }
        if normalised.isEmpty { return root }
        let candidate = root.appendingPathComponent(normalised).standardizedFileURL
        guard candidate.path.hasPrefix(root.standardizedFileURL.path) else {
            throw MemoryError.invalidPath(path)
        }
        if requireExists {
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw MemoryError.notFound(path)
            }
        }
        if mustBeFile {
            let ext = (normalised as NSString).pathExtension.lowercased()
            guard Self.writableExtensions.contains(ext) else {
                throw MemoryError.invalidPath("\(path) — files must end in .md or .json")
            }
        }
        return candidate
    }

    private func normalise(_ path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasPrefix("./") { s.removeFirst(2) }
        let comps = s.split(separator: "/")
        if comps.contains(where: { $0 == ".." }) {
            // Caller will fail at the prefix check; we don't try to repair.
        }
        return comps.joined(separator: "/")
    }

    private func ensureParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func shallowEntries(at url: URL, prefix: String) throws -> [Entry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }
        var out: [Entry] = []
        for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &isDir)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if isDir.boolValue {
                out.append(Entry(path: path, name: name, kind: .folder, sizeBytes: nil, modifiedAt: nil))
            } else {
                let attrs = try? fm.attributesOfItem(atPath: child.path)
                let size = (attrs?[.size] as? Int) ?? 0
                let mtime = attrs?[.modificationDate] as? Date
                out.append(Entry(path: path, name: name, kind: .file, sizeBytes: size, modifiedAt: mtime))
            }
        }
        return out
    }

    private func collectRecursive(at url: URL, relativeTo origin: URL, prefix: String) -> [Entry] {
        var out: [Entry] = []
        guard let entries = try? shallowEntries(at: url, prefix: prefix) else { return out }
        for e in entries {
            out.append(e)
            if e.kind == .folder {
                let child = root.appendingPathComponent(e.path)
                out.append(contentsOf: collectRecursive(at: child, relativeTo: origin, prefix: e.path))
            }
        }
        return out
    }

    private func filesUnder(_ url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(fileURL)
            }
        }
        return out
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }

}

// MARK: - Public value types

public struct MemoryNode: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case folder
        case file(sizeBytes: Int)
    }

    public let name: String
    public let path: String
    public let kind: Kind
    public let children: [MemoryNode]?

    public var id: String { path.isEmpty ? "<root>" : path }
    public var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}

public struct Entry: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case file, folder }
    public let path: String
    public let name: String
    public let kind: Kind
    public let sizeBytes: Int?
    public let modifiedAt: Date?
}

public struct ReadResult: Sendable {
    public let content: String
    public let totalLines: Int
    public let offset: Int
    public let returnedLines: Int
}

public struct GrepHit: Hashable, Sendable {
    public let path: String
    public let line: Int
    public let text: String
}

public enum MemoryError: LocalizedError {
    case invalidPath(String)
    case notFound(String)
    case notADirectory(String)
    case notAFile(String)
    case editNotFound(String)
    case editNotUnique(String, occurrences: Int)
    case invalidEdit(String)
    case folderNotEmpty(String)
    case cannotModifyRoot
    case locked

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let p): return "Invalid memory path: \(p)"
        case .notFound(let p): return "Memory path not found: \(p)"
        case .notADirectory(let p): return "Memory path is not a directory: \(p)"
        case .notAFile(let p): return "Memory path is not a file: \(p)"
        case .editNotFound(let p): return "oldString not found in \(p)"
        case .editNotUnique(let p, let n):
            return "oldString appears \(n) times in \(p) — pass replaceAll=true or use a unique snippet"
        case .invalidEdit(let reason): return "Invalid edit: \(reason)"
        case .folderNotEmpty(let p): return "Folder \(p) is not empty — pass recursive=true"
        case .cannotModifyRoot: return "The memories root cannot be moved or deleted"
        case .locked: return "This app's memories are locked — unlock them to make changes"
        }
    }
}

// MARK: - Glob

/// Very small `**` / `*` / literal segment matcher. Enough for `notes/*.md`,
/// `**/*.md`, `*.md`, `foo/bar.md`. Not a full POSIX glob.
struct GlobMatcher {
    let segments: [Segment]

    enum Segment: Equatable {
        case literal(String)        // exact segment
        case anyName(String)        // pattern like `*.md` — match within one segment
        case anyDepth               // `**`
    }

    init?(_ pattern: String) {
        var parsed: [Segment] = []
        for raw in pattern.split(separator: "/", omittingEmptySubsequences: false) {
            let s = String(raw)
            if s == "**" { parsed.append(.anyDepth) }
            else if s.contains("*") { parsed.append(.anyName(s)) }
            else { parsed.append(.literal(s)) }
        }
        guard !parsed.isEmpty else { return nil }
        self.segments = parsed
    }

    func matches(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return match(segments: segments, parts: parts)
    }

    private func match(segments: [Segment], parts: [String]) -> Bool {
        if segments.isEmpty { return parts.isEmpty }
        let head = segments[0]
        let tail = Array(segments.dropFirst())
        switch head {
        case .anyDepth:
            if tail.isEmpty { return true }
            for i in 0...parts.count {
                if match(segments: tail, parts: Array(parts.dropFirst(i))) { return true }
            }
            return false
        case .literal(let lit):
            guard let p = parts.first, p == lit else { return false }
            return match(segments: tail, parts: Array(parts.dropFirst()))
        case .anyName(let pat):
            guard let p = parts.first, wildcardMatch(pattern: pat, candidate: p) else { return false }
            return match(segments: tail, parts: Array(parts.dropFirst()))
        }
    }

    private func wildcardMatch(pattern: String, candidate: String) -> Bool {
        // Tiny glob within a single segment: `*` matches any run of non-slash chars.
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var idx = candidate.startIndex
        for (i, piece) in parts.enumerated() {
            if i == 0 {
                guard candidate[idx...].hasPrefix(piece) else { return false }
                idx = candidate.index(idx, offsetBy: piece.count)
            } else if i == parts.count - 1 {
                if piece.isEmpty { return true }
                guard candidate.hasSuffix(piece), candidate.distance(from: idx, to: candidate.endIndex) >= piece.count else {
                    return false
                }
                return true
            } else if !piece.isEmpty {
                guard let r = candidate.range(of: piece, range: idx..<candidate.endIndex) else { return false }
                idx = r.upperBound
            }
        }
        return true
    }
}
