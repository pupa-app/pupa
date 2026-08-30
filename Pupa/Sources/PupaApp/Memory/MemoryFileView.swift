import SwiftUI
import MarkdownUI

/// Renders a single file from the user's memories. `.md` gets a GitHub-style
/// markdown column; anything else (`.json`) is shown verbatim as monospaced,
/// horizontally scrolling code so newlines and indentation survive. Supports an
/// inline Edit / Preview toggle so the user can paste content directly into a
/// note without going through the agent.
///
/// **Concurrent edit safety.** If the agent rewrites the same file while the
/// user is mid-edit, the user's `editBuffer` is preserved — their next Save
/// wins. Outside edit mode, agent-driven rescans refresh the preview.
public struct MemoryFileView: View {
    @Bindable var store: MemoryStore
    /// Global-root-relative (`<appId>/notes/a.md`, `orchestrator/journal.md`) —
    /// the space the shared store reads from. Displayed scope-relative; see
    /// `displayPath`.
    let path: String
    /// When true (the file's app has locked memories), Edit / Delete are hidden
    /// and the note is preview-only.
    var readOnly: Bool = false
    /// Presented as a sheet: a dismissal (swipe included) commits the edit
    /// instead of dropping it. See `MemoryFileDismiss`.
    var autosavesOnDismiss: Bool = false
    /// Editor text to restore instead of loading from disk — set when a failed
    /// autosave re-presents this file, so the user's work survives.
    var restoredBuffer: String?
    /// Called when an autosave on dismissal failed, with the message and the
    /// buffer that didn't make it, so the host can put both back on screen.
    var onAutosaveFailed: (String, String) -> Void = { _, _ in }

    /// False inside an imported app until the user opts in. See
    /// `MyApp.allowsRemoteImages`.
    @Environment(\.remoteImagesAllowed) private var remoteImagesAllowed
    var onDeleted: () -> Void

    /// Last content loaded from disk. The Cancel button reverts to this.
    @State private var loadedContent: String = ""
    /// In-flight edit buffer. Equal to `loadedContent` when no unsaved edits.
    @State private var editBuffer: String = ""
    @State private var isEditing: Bool = false
    @State private var error: String?
    @State private var showDiscardAlert: Bool = false

    public init(
        store: MemoryStore,
        path: String,
        readOnly: Bool = false,
        autosavesOnDismiss: Bool = false,
        restoredBuffer: String? = nil,
        onAutosaveFailed: @escaping (String, String) -> Void = { _, _ in },
        onDeleted: @escaping () -> Void
    ) {
        self.store = store
        self.path = path
        self.readOnly = readOnly
        self.autosavesOnDismiss = autosavesOnDismiss
        self.restoredBuffer = restoredBuffer
        self.onAutosaveFailed = onAutosaveFailed
        self.onDeleted = onDeleted
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                } else if isEditing {
                    TextEditor(text: $editBuffer)
                        .font(.body.monospaced())
                        .frame(minHeight: 420, idealHeight: 640)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                } else if MemoryFilenameHelper.rendersAsMarkdown(path) {
                    Markdown(loadedContent)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        // Memory files ride in imported bundles, and MarkdownUI's
                        // default provider fetches on render — an image URL in
                        // one is a callout the moment the note is opened.
                        .markdownImageProvider(.gated(allowed: remoteImagesAllowed))
                } else {
                    codeView
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
        .task(id: path) {
            isEditing = false
            reload()
            // A failed autosave re-presents this file; drop the user back into
            // the editor holding the text that didn't make it to disk.
            if let restoredBuffer {
                editBuffer = restoredBuffer
                isEditing = true
            }
        }
        .onDisappear {
            guard autosavesOnDismiss else { return }
            guard MemoryFileDismiss.shouldSave(
                readOnly: readOnly,
                isEditing: isEditing,
                buffer: editBuffer,
                loaded: loadedContent
            ) else { return }
            do {
                try store.writeFile(path: path, content: editBuffer)
            } catch {
                onAutosaveFailed(error.localizedDescription, editBuffer)
            }
        }
        .onChange(of: store.tree.id) { _, _ in
            // Agent-driven rescans refresh the preview, but only when the user
            // isn't holding unsaved edits — otherwise their buffer would be
            // silently clobbered by whatever the agent just wrote.
            if !isEditing { reload() }
        }
        .alert("Discard changes?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                editBuffer = loadedContent
                isEditing = false
            }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your unsaved changes to this note will be lost.")
        }
    }

    private var hasUnsavedChanges: Bool {
        isEditing && editBuffer != loadedContent
    }

    /// Verbatim preview for non-markdown files. `Text` is left unconstrained so
    /// it takes its unwrapped ideal width and long lines scroll instead of
    /// reflowing; the background sits on the scroll view so it spans the column.
    private var codeView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(loadedContent)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// `path` without its scope-root segment — the app's uuid folder, or
    /// `orchestrator/`. Showing the raw path would put a 36-char uuid in the
    /// title; scope-relative is also what the agent and the Memories tree use.
    /// A path with no separator is already scope-relative.
    var displayPath: String {
        guard let slash = path.firstIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// "Memory file" for markdown, "JSON file" otherwise.
    private var kindLabel: String {
        if MemoryFilenameHelper.rendersAsMarkdown(path) { return "Memory file" }
        return "\((path as NSString).pathExtension.uppercased()) file"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayPath)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(kindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasUnsavedChanges {
                        Text("• Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if readOnly {
                Label("Locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            } else if isEditing {
                Button("Cancel", action: cancelEdits)
                    .buttonStyle(.borderless)
                Button("Save", action: saveEdits)
                    .buttonStyle(.borderedProminent)
                    .disabled(editBuffer == loadedContent)
            } else {
                Button {
                    startEditing()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    deleteFile()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func reload() {
        do {
            let content = try store.readFile(path: path).content
            loadedContent = content
            if !isEditing {
                editBuffer = content
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            loadedContent = ""
            if !isEditing {
                editBuffer = ""
            }
        }
    }

    private func startEditing() {
        editBuffer = loadedContent
        isEditing = true
    }

    private func saveEdits() {
        do {
            try store.writeFile(path: path, content: editBuffer)
            loadedContent = editBuffer
            isEditing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancelEdits() {
        if hasUnsavedChanges {
            showDiscardAlert = true
        } else {
            isEditing = false
        }
    }

    private func deleteFile() {
        do {
            try store.delete(path: path, recursive: false)
            onDeleted()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
