import SwiftUI
import MarkdownUI

/// Renders a single markdown file from the user's memories in a GitHub-style
/// column. Supports an inline Edit / Preview toggle so the user can paste
/// content directly into a note without going through the agent.
///
/// **Concurrent edit safety.** If the agent rewrites the same file while the
/// user is mid-edit, the user's `editBuffer` is preserved — their next Save
/// wins. Outside edit mode, agent-driven rescans refresh the preview.
public struct MemoryFileView: View {
    @Bindable var store: MemoryStore
    let path: String
    var onDeleted: () -> Void

    /// Last content loaded from disk. The Cancel button reverts to this.
    @State private var loadedContent: String = ""
    /// In-flight edit buffer. Equal to `loadedContent` when no unsaved edits.
    @State private var editBuffer: String = ""
    @State private var isEditing: Bool = false
    @State private var error: String?
    @State private var showDiscardAlert: Bool = false

    public init(store: MemoryStore, path: String, onDeleted: @escaping () -> Void) {
        self.store = store
        self.path = path
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
                } else {
                    Markdown(loadedContent)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(path)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("Memory file")
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
            if isEditing {
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
