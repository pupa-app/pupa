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

    public init(rootOverride: URL? = nil) {
        self.root = rootOverride ?? Self.defaultRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.tree = Self.scan(root: root)
    }

    // MARK: - Public filesystem API

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
        let url = try resolve(path, requireExists: false, mustBeFile: true)
        try ensureParent(of: url)
        try content.data(using: .utf8)!.write(to: url, options: .atomic)
        rescan()
        return content.utf8.count
    }

    @discardableResult
    public func appendFile(path: String, content: String) throws -> Int {
        let url = try resolve(path, requireExists: false, mustBeFile: true)
        try ensureParent(of: url)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = content.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } else {
            try content.data(using: .utf8)!.write(to: url, options: .atomic)
        }
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
        guard !oldString.isEmpty else { throw MemoryError.invalidEdit("oldString is empty") }
        guard oldString != newString else { throw MemoryError.invalidEdit("oldString == newString") }
        let url = try resolve(path, requireExists: true, mustBeFile: true)
        let original = try String(contentsOf: url, encoding: .utf8)
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
        try updated.data(using: .utf8)!.write(to: url, options: .atomic)
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
        let src = try resolve(from, requireExists: true)
        let dst = try resolve(to, requireExists: false)
        try ensureParent(of: dst)
        try FileManager.default.moveItem(at: src, to: dst)
        rescan()
    }

    public func delete(path: String, recursive: Bool = false) throws {
        let url = try resolve(path, requireExists: true)
        guard url != root else { throw MemoryError.cannotModifyRoot }
        if isDirectory(url) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if !contents.isEmpty && !recursive {
                throw MemoryError.folderNotEmpty(path)
            }
        }
        try FileManager.default.removeItem(at: url)
        rescan()
    }

    public func createFolder(path: String) throws {
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

    // MARK: - Private

    private static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("pupa/memories", isDirectory: true)
    }

    // MARK: - Path helpers for structured namespace

    /// Top-level folder for a myApp: `<slug>` (e.g. `"my-fitness-app"`).
    public static func myAppFolder(myAppName: String) -> String {
        slugify(myAppName)
    }

    /// Top-level folder for the orchestrator's memories.
    public static func orchestratorFolder() -> String { "orchestrator" }

    /// Absolute URL for a myApp's memory root — used as `rootOverride` when
    /// creating a session-scoped `MemoryStore`.
    public static func appRoot(myAppName: String) -> URL {
        defaultRoot().appendingPathComponent(myAppFolder(myAppName: myAppName), isDirectory: true)
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

    /// Private subfolder for a named Slack agent within the global root:
    /// `<myAppSlug>/slack/<agentNameSlug>` (e.g. `"my-fitness-app/slack/marketing"`).
    public static func slackAgentFolder(myAppName: String, agentName: String) -> String {
        "\(componentFolder(myAppName: myAppName, componentKind: "slack"))/\(slugify(agentName))"
    }

    /// Relative path within an app-scoped `MemoryStore` for a named Slack
    /// agent: `slack/<agentNameSlug>` (e.g. `"slack/marketing"`).
    public static func slackAgentSubfolder(agentName: String) -> String {
        "slack/\(slugify(agentName))"
    }

    /// Lower-case alphanumerics + hyphens, no consecutive hyphens, capped at
    /// 60 characters. Mirrors `MemorySheets.slugify` without a SwiftUI import.
    static func slugify(_ raw: String, maxLength: Int = 60) -> String {
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

    private static func scan(root: URL) -> MemoryNode {
        let children = readChildren(at: root, prefix: "")
        return MemoryNode(name: "", path: "", kind: .folder, children: children)
    }

    private static func readChildren(at url: URL, prefix: String) -> [MemoryNode] {
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
        if mustBeFile && !normalised.lowercased().hasSuffix(".md") {
            throw MemoryError.invalidPath("\(path) — files must end in .md")
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

public struct MemoryNode: Hashable, Identifiable {
    public enum Kind: Hashable {
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
