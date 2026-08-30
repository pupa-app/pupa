import SwiftUI

/// Sheets that drive direct (non-agent) mutation of the Memories filesystem
/// from the sidebar. The data layer lives in `MemoryStore` — these views are
/// thin shells around `writeFile`, `createFolder`, and `move`.
///
/// Sheet routing uses `MemorySheet` as an `Identifiable` enum so the host can
/// drive everything from a single `@State var activeMemorySheet: MemorySheet?`
/// bound via `.sheet(item:)`.
public enum MemorySheet: Identifiable, Hashable {
    /// Create a new `.md` note inside `parent` (root if `""`).
    case newNote(parent: String)
    /// Create a new subfolder inside `parent` (root if `""`).
    case newFolder(parent: String)
    /// Rename or move an existing file / folder.
    case rename(path: String)

    public var id: String {
        switch self {
        case .newNote(let p): return "newNote:\(p)"
        case .newFolder(let p): return "newFolder:\(p)"
        case .rename(let p): return "rename:\(p)"
        }
    }
}

// MARK: - New note

public struct NewMemoryNoteSheet: View {
    @Bindable var memory: MemoryStore
    let parent: String
    var onClose: () -> Void
    var onCreated: (String) -> Void

    @State private var name: String = ""
    @State private var content: String = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    public init(
        memory: MemoryStore,
        parent: String,
        onClose: @escaping () -> Void,
        onCreated: @escaping (String) -> Void = { _ in }
    ) {
        self.memory = memory
        self.parent = parent
        self.onClose = onClose
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. diet, workouts (\".md\" added unless you type .md / .json)", text: $name)
                        .focused($nameFocused)
                }
                Section("Content") {
                    TextEditor(text: $content)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(parent.isEmpty ? "New note" : "New note in \(parent)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: commit)
                        .disabled(!canCommit)
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 480)
            #endif
        }
        .onAppear { nameFocused = true }
    }

    private var canCommit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        let resolvedName = MemoryFilenameHelper.resolveFilename(name: name, content: content)
        guard !resolvedName.isEmpty else {
            error = "Enter a name or some content."
            return
        }
        let fullPath = MemoryFilenameHelper.join(parent: parent, name: resolvedName)
        if memory.fileExists(at: fullPath) {
            error = "A note named “\(resolvedName)” already exists in this folder."
            return
        }
        do {
            try memory.writeFile(path: fullPath, content: content)
            // Close before handing the path on: `onCreated` now *presents* the
            // new note as a sheet, and presenting while this one is still up is
            // dropped by the host.
            onClose()
            onCreated(fullPath)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - New folder

public struct NewMemoryFolderSheet: View {
    @Bindable var memory: MemoryStore
    let parent: String
    var onClose: () -> Void
    var onCreated: (String) -> Void

    @State private var name: String = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    public init(
        memory: MemoryStore,
        parent: String,
        onClose: @escaping () -> Void,
        onCreated: @escaping (String) -> Void = { _ in }
    ) {
        self.memory = memory
        self.parent = parent
        self.onClose = onClose
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Folder name") {
                    TextField("e.g. notes, recipes", text: $name)
                        .focused($nameFocused)
                        .onSubmit(commit)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(parent.isEmpty ? "New folder" : "New folder in \(parent)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: commit)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 180, idealHeight: 220)
            #endif
        }
        .onAppear { nameFocused = true }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains("/") {
            error = "Folder name can’t contain “/”."
            return
        }
        let fullPath = MemoryFilenameHelper.join(parent: parent, name: trimmed)
        if memory.fileExists(at: fullPath) || memory.folderExists(at: fullPath) {
            error = "A file or folder named “\(trimmed)” already exists."
            return
        }
        do {
            try memory.createFolder(path: fullPath)
            onCreated(fullPath)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Rename or move

public struct RenameMemorySheet: View {
    @Bindable var memory: MemoryStore
    let path: String
    var onClose: () -> Void
    var onMoved: (_ from: String, _ to: String) -> Void

    @State private var draft: String = ""
    @State private var error: String?
    @FocusState private var pathFocused: Bool

    public init(
        memory: MemoryStore,
        path: String,
        onClose: @escaping () -> Void,
        onMoved: @escaping (_ from: String, _ to: String) -> Void = { _, _ in }
    ) {
        self.memory = memory
        self.path = path
        self.onClose = onClose
        self.onMoved = onMoved
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("New path") {
                    TextField("relative path", text: $draft)
                        .focused($pathFocused)
                        .onSubmit(commit)
                    Text("Edit the folder portion to move, the last segment to rename.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename or move")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(!canCommit)
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 200, idealHeight: 240)
            #endif
        }
        .onAppear {
            draft = path
            pathFocused = true
        }
    }

    private var canCommit: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != path
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != path else { return }
        if memory.fileExists(at: trimmed) || memory.folderExists(at: trimmed) {
            error = "A file or folder already exists at “\(trimmed)”."
            return
        }
        do {
            try memory.move(from: path, to: trimmed)
            onMoved(path, trimmed)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Helpers

/// Filename / path helpers shared by the memory sheets. Pure functions so
/// they're easy to unit-test without standing up a `MemoryStore`.
public enum MemoryFilenameHelper {
    /// Compute the filename a new note should use. If the user typed a name,
    /// trim it and ensure it ends in a store-writable extension (`.md` /
    /// `.json`), appending `.md` otherwise. Without a name, derive a slug from
    /// the first non-empty content line (strip leading `#`/`-`/`*` markdown
    /// markers). Falls back to `"untitled.md"` only if both are empty.
    public static func resolveFilename(name: String, content: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return ensureSupportedExtension(trimmedName)
        }
        if let firstLine = content
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            var stripped = firstLine.trimmingCharacters(in: .whitespaces)
            while let prefix = ["#", "-", "*", ">"].first(where: { stripped.hasPrefix($0) }) {
                stripped.removeFirst(prefix.count)
                stripped = stripped.trimmingCharacters(in: .whitespaces)
            }
            let slug = slugify(stripped)
            if !slug.isEmpty {
                return "\(slug).md"
            }
        }
        let bothEmpty = trimmedName.isEmpty
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return bothEmpty ? "" : "untitled.md"
    }

    /// Join `parent` and a leaf name into a relative memory path. Handles
    /// empty parents (root) without producing leading slashes.
    public static func join(parent: String, name: String) -> String {
        let p = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let n = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if p.isEmpty { return n }
        if n.isEmpty { return p }
        return "\(p)/\(n)"
    }

    /// Lower-case alphanumerics + hyphens, no consecutive hyphens, capped at
    /// 60 characters. Used to suggest filenames from a first content line.
    public static func slugify(_ raw: String, maxLength: Int = 60) -> String {
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
            // every other character is dropped
            if out.count >= maxLength { break }
        }
        while out.last == "-" { out.removeLast() }
        return String(out)
    }

    /// True when a memory file should be previewed as rendered markdown. Only
    /// `.md` and extensionless files qualify — everything else (`.json`, or an
    /// arbitrary extension smuggled in by a rename) is shown verbatim as code,
    /// since markdown rendering eats its newlines and indentation.
    public static func rendersAsMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty || ext == "md"
    }

    /// Keep an extension the store can write (`MemoryStore.writableExtensions`);
    /// append `.md` to anything else, so `notes.v2` → `notes.v2.md`.
    private static func ensureSupportedExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return MemoryStore.writableExtensions.contains(ext) ? name : "\(name).md"
    }
}
