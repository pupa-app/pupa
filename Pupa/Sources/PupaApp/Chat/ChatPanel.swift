import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MarkdownUI

public struct AgentPickerEntry: Identifiable {
    public let scope: ChatScope
    public let name: String
    public let icon: String
    public let color: Color

    public var id: String {
        switch scope {
        case .memory: return "orchestrator"
        case .myApp(let id): return id.uuidString
        }
    }
}

public struct ChatPanel: View {
    @Bindable var viewModel: ChatViewModel
    /// Title of the current conversation thread. `nil` when the thread has no
    /// title yet (no messages sent). Shown in the header next to the agent name.
    let currentThreadTitle: String?
    let agents: [AgentPickerEntry]
    let onSwitchAgent: (ChatScope) -> Void
    /// Called when the user taps the `+` button to start a new conversation.
    let onAddThread: (() -> Void)?
    /// Called when the user deletes the current thread. `nil` when only one
    /// thread exists (delete is not offered).
    let onDeleteThread: (() -> Void)?
    @State private var draft: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: PickedImage?
    @State private var isLoadingImage: Bool = false
    @State private var isDropTargeted: Bool = false

    public init(
        viewModel: ChatViewModel,
        currentThreadTitle: String? = nil,
        agents: [AgentPickerEntry],
        onSwitchAgent: @escaping (ChatScope) -> Void,
        onAddThread: (() -> Void)? = nil,
        onDeleteThread: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.currentThreadTitle = currentThreadTitle
        self.agents = agents
        self.onSwitchAgent = onSwitchAgent
        self.onAddThread = onAddThread
        self.onDeleteThread = onDeleteThread
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.bubbles) { bubble in
                            MessageBubbleView(
                                bubble: bubble,
                                verbose: viewModel.verbose,
                                pendingAnswers: viewModel.pendingAnswers,
                                pendingBubbleId: viewModel.hasPendingQuestion ? bubble.id : nil,
                                pendingComplete: viewModel.pendingAnswersComplete,
                                shellApprovalBubbleId: viewModel.hasPendingShellApproval ? bubble.id : nil,
                                onSetAnswer: { rowIndex, value in
                                    viewModel.setPendingAnswer(rowIndex: rowIndex, value: value)
                                },
                                onSubmitAnswers: {
                                    viewModel.submitInterruptAnswers()
                                },
                                onApproveShell: { remember in
                                    viewModel.submitShellApproval(approved: true, remember: remember)
                                },
                                onDenyShell: {
                                    viewModel.submitShellApproval(approved: false, remember: false)
                                },
                                onToggleExpansion: { id in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(id, anchor: .top)
                                    }
                                }
                            ).id(bubble.id)
                        }
                        if let error = viewModel.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel.bubbles.count) { _, _ in
                    if let last = viewModel.bubbles.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        .onAppear {
            // First chat opened after onboarding: pre-fill the composer with a
            // suggested message so the user's first action is a single tap.
            // Consume-once, so ordinary chat opens are untouched.
            if draft.isEmpty, !viewModel.isStreaming,
               let suggested = OnboardingHandoff.shared.consumeSuggestedPrompt() {
                draft = suggested
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            agentDropdown
            if let title = currentThreadTitle {
                Text("· \(title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if let add = onAddThread {
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New conversation")
            }
            if let icon = AppIcon.swiftUIImage {
                icon
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel("Pupa")
            } else {
                Text("Pupa").font(.subheadline).bold()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var agentDropdown: some View {
        let current = agents.first(where: { $0.scope == viewModel.pinnedScope })
        Menu {
            ForEach(agents) { entry in
                Button {
                    onSwitchAgent(entry.scope)
                } label: {
                    Label(entry.name, systemImage: entry.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let icon = current?.icon {
                    Image(systemName: icon)
                        .foregroundStyle(viewModel.agentColor)
                }
                Text(viewModel.agentDisplayName)
                    .font(.subheadline).bold()
                    .foregroundStyle(viewModel.agentColor)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(viewModel.agentColor.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let prefix = activeSlashPrefix {
                    SlashCommandPalette(
                        commands: viewModel.slashCommands.filter(prefix: prefix),
                        onPick: { name in
                            draft = "/\(name) "
                        }
                    )
                }
                if let pickedImage {
                    attachmentPreview(for: pickedImage)
                } else if isDropTargeted {
                    Text("Drop image to attach")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 8) {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "paperclip")
                            .padding(8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isStreaming || isLoadingImage)
                    .help("Attach an image (or drag & drop one onto the chat)")
                    TextField(composerPlaceholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(viewModel.isStreaming || viewModel.hasPendingQuestion)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                            .padding(8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sendDisabled)
                }
            }
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.7 : 0), lineWidth: 2)
                    .padding(4)
            )
            .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            isLoadingImage = true
            Task {
                let prepared: PickedImage? = await loadPickedImage(from: newItem)
                await MainActor.run {
                    self.pickedImage = prepared
                    self.isLoadingImage = false
                    self.pickerItem = nil
                }
            }
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        guard !viewModel.isStreaming, !isLoadingImage else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            isLoadingImage = true
            Task { await acceptImageProvider(provider) }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            isLoadingImage = true
            Task { await acceptFileURLProvider(provider) }
            return true
        }
        return false
    }

    private func acceptImageProvider(_ provider: NSItemProvider) async {
        let raw: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        applyDroppedRawData(raw)
    }

    private func acceptFileURLProvider(_ provider: NSItemProvider) async {
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        let raw: Data? = url.flatMap { try? Data(contentsOf: $0) }
        applyDroppedRawData(raw)
    }

    @MainActor
    private func applyDroppedRawData(_ raw: Data?) {
        defer { isLoadingImage = false }
        guard let raw, let prepared = ImagePreparer.prepare(raw) else { return }
        pickedImage = PickedImage(data: prepared.data, mimeType: prepared.mimeType)
    }

    /// When the draft is a partial slash command (slash followed by zero or
    /// more word characters, no whitespace), return the substring after the
    /// slash so the palette can filter on it. Returns `nil` otherwise so the
    /// palette stays hidden — e.g. once the user types a space after the
    /// command name (entering "args" territory) or for plain text.
    private var activeSlashPrefix: String? {
        guard draft.first == "/" else { return nil }
        let rest = draft.dropFirst()
        if rest.contains(where: { $0.isWhitespace }) { return nil }
        if !rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { return nil }
        return String(rest)
    }

    private var sendDisabled: Bool {
        if viewModel.isStreaming { return false }  // tap = cancel
        if isLoadingImage { return true }
        return draft.trimmingCharacters(in: .whitespaces).isEmpty && pickedImage == nil
    }

    /// The TextField is disabled while a turn is in flight, so swap the
    /// placeholder so the lock state is self-explanatory and the user
    /// knows Stop is their only mid-turn action. When the agent is parked
    /// on an `ask_user_questions` interrupt the composer is gated too —
    /// answers travel through the bubble's Submit button, not the
    /// composer, so the placeholder explains where to reply.
    private var composerPlaceholder: String {
        if viewModel.isStreaming { return "Streaming… tap Stop to cancel" }
        if viewModel.hasPendingQuestion { return "Answer above and tap Submit…" }
        return "Type a message or /reset…"
    }

    @ViewBuilder
    private func attachmentPreview(for image: PickedImage) -> some View {
        HStack(spacing: 8) {
            attachmentThumbnail(image.data)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(byteCountLabel(image.data.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                pickedImage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
    }

    private func byteCountLabel(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .binary
        return f.string(fromByteCount: Int64(bytes))
    }

    private func send() {
        if viewModel.isStreaming {
            viewModel.cancel()
            return
        }
        viewModel.send(draft, image: pickedImage)
        draft = ""
        pickedImage = nil
    }

    private func loadPickedImage(from item: PhotosPickerItem) async -> PickedImage? {
        do {
            guard let raw = try await item.loadTransferable(type: Data.self) else { return nil }
            guard let prepared = ImagePreparer.prepare(raw) else { return nil }
            return PickedImage(data: prepared.data, mimeType: prepared.mimeType)
        } catch {
            return nil
        }
    }
}

private struct MessageBubbleView: View {
    let bubble: ChatBubble
    let verbose: Bool
    /// The viewmodel's in-progress answers for the currently-pending
    /// interrupt, indexed by question row. The bubble reads its own row's
    /// value from this array (matched against `pendingBubbleId`); writes
    /// flow through `onSetAnswer` so the viewmodel stays the source of
    /// truth and SwiftUI re-renders cleanly when the user interacts.
    let pendingAnswers: [String]
    /// The bubble id that owns the currently-pending interrupt, or `nil`
    /// when no interrupt is active. The `humanQuestion` bubble reads this
    /// to decide whether its inputs are live or locked: bubbles from
    /// historic interrupts render in read-only mode.
    let pendingBubbleId: String?
    /// Mirrors `ChatViewModel.pendingAnswersComplete`. The Submit button
    /// is enabled only when every row has a non-empty answer.
    let pendingComplete: Bool
    /// The bubble id that owns the currently-pending shell approval interrupt,
    /// or `nil` when no approval is pending. Mirrors `pendingBubbleId`.
    let shellApprovalBubbleId: String?
    /// Tapped when the user picks an option or types into a row's inline
    /// "Other" field. The viewmodel updates `pendingAnswers[rowIndex]`.
    let onSetAnswer: (Int, String) -> Void
    /// Tapped when the user hits the bubble's Submit button. The
    /// viewmodel resumes the parked graph with the collected answers.
    let onSubmitAnswers: () -> Void
    /// Called with `remember: Bool` when the user taps Approve on a shell approval bubble.
    let onApproveShell: (Bool) -> Void
    /// Called when the user taps Deny on a shell approval bubble.
    let onDenyShell: () -> Void
    /// Forwarded to bubbles with an expand/collapse toggle (system, toolRound)
    /// so they can ask the parent ScrollView to keep the bubble in view when
    /// its height changes.
    let onToggleExpansion: (String) -> Void

    var body: some View {
        switch bubble.role {
        case .system:
            SystemBubbleView(bubble: bubble, onToggleExpansion: onToggleExpansion)
                .id(bubble.id)
        case .toolRound:
            ToolRoundBubbleView(bubble: bubble, verbose: verbose, onToggleExpansion: onToggleExpansion)
        case .shellApproval:
            ShellApprovalBubbleView(
                bubble: bubble,
                isLive: shellApprovalBubbleId == bubble.id,
                onApprove: onApproveShell,
                onDeny: onDenyShell
            )
        case .humanQuestion:
            HumanQuestionBubbleView(
                bubble: bubble,
                isLive: pendingBubbleId == bubble.id,
                pendingAnswers: pendingAnswers,
                pendingComplete: pendingComplete,
                onSetAnswer: onSetAnswer,
                onSubmitAnswers: onSubmitAnswers
            )
        case .user, .assistant:
            HStack {
                if bubble.role == .user { Spacer(minLength: 40) }
                VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 6) {
                    if let data = bubble.imageData {
                        attachmentThumbnail(data)
                            .frame(maxWidth: 240, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if !bubble.text.isEmpty || bubble.imageData == nil {
                        if bubble.role == .assistant {
                            Markdown(bubble.text.isEmpty ? "…" : bubble.text)
                                .markdownTheme(
                                    .gitHub
                                        .text {
                                            ForegroundColor(.primary)
                                            BackgroundColor(nil)
                                            FontSize(16)
                                        }
                                        .codeBlock { configuration in
                                            configuration.label
                                                .relativeLineSpacing(.em(0.225))
                                                .markdownTextStyle {
                                                    FontFamilyVariant(.monospaced)
                                                    FontSize(.em(0.85))
                                                }
                                                .padding(16)
                                                .background(Color.primary.opacity(0.06))
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                )
                                #if os(iOS)
                                .textSelection(.enabled)
                                #endif
                        } else {
                            Text(bubble.text.isEmpty ? "…" : bubble.text)
                        }
                    }
                }
                .padding(10)
                .background(bubble.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
                if bubble.role == .assistant { Spacer(minLength: 40) }
            }
        }
    }
}

/// Renders a `.system` bubble — local-only client text emitted by slash
/// commands (`/help`, `/tools`, `/ag-ui-payload`, "Unknown command" errors).
///
/// Behaviour: short bubbles (≤ `threshold` lines) render in full. Long ones
/// collapse by default to the first `threshold` lines plus a
/// "Show more (N more lines)" toggle; once expanded, a "Show less" toggle
/// flips state back. The expand state is per-bubble view state and never
/// mutates the underlying `bubble.text`. Pinning a `.id(bubble.id)` on the
/// view at the call site keeps state stable across LazyVStack recycles so
/// expanding one bubble doesn't bleed into another.
private struct SystemBubbleView: View {
    let bubble: ChatBubble
    /// Invoked after the user toggles expansion so the parent ScrollView can
    /// scroll the bubble back into view — otherwise collapsing leaves the
    /// (now-short) bubble above the viewport and the user has to scroll up.
    let onToggleExpansion: (String) -> Void
    @State private var isExpanded: Bool = false

    /// Maximum lines shown before the collapse toggle appears. Bubbles at or
    /// below this length render unchanged (no toggle).
    private static let threshold: Int = 12

    var body: some View {
        let lines = bubble.text.components(separatedBy: "\n")
        let lineCount = lines.count
        let overThreshold = lineCount > Self.threshold
        let visibleText: String = {
            if !overThreshold || isExpanded { return bubble.text }
            return lines.prefix(Self.threshold).joined(separator: "\n")
        }()

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(visibleText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if overThreshold {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
                        onToggleExpansion(bubble.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            if isExpanded {
                                Text("Show less")
                            } else {
                                Text("Show more (\(lineCount - Self.threshold) more lines)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Approval card shown when the backend's `ShellApprovalMiddleware` pauses
/// before executing a shell command. The graph is interrupted; the user
/// taps Approve (optionally with "Always allow") or Deny; the result
/// resumes via `ChatViewModel.submitShellApproval`.
///
/// Visual contract: orange tint + terminal glyph, distinct from the yellow
/// `humanQuestion` bubble so the user recognises the security context.
private struct ShellApprovalBubbleView: View {
    let bubble: ChatBubble
    let isLive: Bool
    let onApprove: (Bool) -> Void
    let onDeny: () -> Void

    @State private var remember: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                Text("Allow shell command?")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(bubble.text)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLive {
                    Toggle("Always allow this session", isOn: $remember)
                        .font(.caption)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Deny") { onDeny() }
                            .buttonStyle(.bordered)
                        Button {
                            onApprove(remember)
                        } label: {
                            Text("Approve")
                                .frame(minWidth: 80)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A clarifying-question panel raised by the agent via the
/// `ask_user_questions` backend tool. The graph is paused on a LangGraph
/// `interrupt(...)`; the user picks an option or types a custom reply per
/// question and taps Submit; `ChatViewModel.submitInterruptAnswers()`
/// routes the collected list into `AgentSession.resume(answers:)`.
///
/// Visual contract: yellow tint + question-mark glyph so the user can tell
/// at a glance the agent is waiting on them. When `isLive` is false the
/// bubble renders the historical state read-only (a previously-submitted
/// panel staying in the transcript for context).
private struct HumanQuestionBubbleView: View {
    let bubble: ChatBubble
    let isLive: Bool
    let pendingAnswers: [String]
    let pendingComplete: Bool
    let onSetAnswer: (Int, String) -> Void
    let onSubmitAnswers: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.yellow)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(bubble.humanQuestions.enumerated()), id: \.offset) { rowIdx, row in
                    questionRow(rowIdx: rowIdx, row: row)
                }
                if isLive {
                    Button {
                        onSubmitAnswers()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Submit")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!pendingComplete)
                    .help(pendingComplete
                          ? "Send all answers and continue."
                          : "Fill in every question before submitting.")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.yellow.opacity(isLive ? 0.55 : 0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 460, alignment: .leading)
    }

    /// One question row: question text, then either tappable options (when
    /// the agent supplied any) or a single inline TextField for an
    /// open-ended question. The "Other…" affordance is rendered when there
    /// ARE options; tapping it reveals an inline TextField below them so
    /// the user can type a custom answer that still counts toward this
    /// row's answer.
    @ViewBuilder
    private func questionRow(rowIdx: Int, row: HumanQuestionRow) -> some View {
        let currentAnswer = pendingAnswers.indices.contains(rowIdx) ? pendingAnswers[rowIdx] : ""
        let isOptionPicked = row.options.contains(currentAnswer)
        let otherExpanded = OtherInteractionStore.shared.isExpanded(bubbleId: bubble.id, rowIdx: rowIdx)
        let showingOther = !row.options.isEmpty && !isOptionPicked && (!currentAnswer.isEmpty || otherExpanded)

        VStack(alignment: .leading, spacing: 6) {
            Text(row.question)
                .italic()
                .textSelection(.enabled)
            if row.options.isEmpty {
                inlineTextField(rowIdx: rowIdx, current: currentAnswer)
            } else {
                ForEach(Array(row.options.enumerated()), id: \.offset) { optIdx, option in
                    optionButton(
                        rowIdx: rowIdx,
                        optIdx: optIdx,
                        option: option,
                        isSelected: currentAnswer == option
                    )
                }
                Button {
                    OtherInteractionStore.shared.expand(bubbleId: bubble.id, rowIdx: rowIdx)
                    // Clear any selected option so the row's answer comes
                    // from the inline text field instead.
                    if isOptionPicked {
                        onSetAnswer(rowIdx, "")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Other…")
                            .italic()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(!isLive)
                if showingOther {
                    inlineTextField(rowIdx: rowIdx, current: currentAnswer)
                }
            }
        }
    }

    @ViewBuilder
    private func optionButton(rowIdx: Int, optIdx: Int, option: String, isSelected: Bool) -> some View {
        // Selected options use `.borderedProminent` (filled) and unselected
        // use `.bordered` (outline). Selecting a duplicate button styles
        // via a viewmodifier-conditional Group rather than a type-erased
        // ButtonStyle because the system bordered styles are
        // `PrimitiveButtonStyle`, which doesn't compose with a generic
        // ButtonStyle wrapper.
        Group {
            if isSelected {
                Button { tapOption(rowIdx: rowIdx, option: option) } label: { optionLabel(optIdx: optIdx, option: option, isSelected: true) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { tapOption(rowIdx: rowIdx, option: option) } label: { optionLabel(optIdx: optIdx, option: option, isSelected: false) }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(!isLive)
    }

    private func tapOption(rowIdx: Int, option: String) {
        onSetAnswer(rowIdx, option)
        OtherInteractionStore.shared.collapse(bubbleId: bubble.id, rowIdx: rowIdx)
    }

    @ViewBuilder
    private func optionLabel(optIdx: Int, option: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(optIdx + 1)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(option)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineTextField(rowIdx: Int, current: String) -> some View {
        TextField(
            "Type a custom reply…",
            text: Binding(
                get: { current },
                set: { onSetAnswer(rowIdx, $0) }
            ),
            axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...3)
        .disabled(!isLive)
    }
}

/// Per-bubble "Other…" expand/collapse state. Kept outside SwiftUI's
/// `@State` because the bubble view recycles inside the LazyVStack and
/// can lose local state when scrolled off screen — but we want the
/// inline TextField to stay visible once the user has expanded it. Keyed
/// by `(bubbleId, rowIdx)` so each row is independent.
@MainActor
private final class OtherInteractionStore {
    static let shared = OtherInteractionStore()
    private var expanded: Set<String> = []
    private func key(bubbleId: String, rowIdx: Int) -> String { "\(bubbleId)#\(rowIdx)" }
    func isExpanded(bubbleId: String, rowIdx: Int) -> Bool {
        expanded.contains(key(bubbleId: bubbleId, rowIdx: rowIdx))
    }
    func expand(bubbleId: String, rowIdx: Int) {
        expanded.insert(key(bubbleId: bubbleId, rowIdx: rowIdx))
    }
    func collapse(bubbleId: String, rowIdx: Int) {
        expanded.remove(key(bubbleId: bubbleId, rowIdx: rowIdx))
    }
}

/// One row per round of tool calls. Collapsed by default, showing a one-line
/// summary ("Calling N tools…" with spinner while any entry is `.pending`,
/// "Used N tools" with a checkmark once they're all `.done`, "Used N tools —
/// K failed" when any failed). Expanding reveals each call: name + status icon
/// always, plus pretty-printed args and result when `verbose` is on (the
/// `/verbose` flag on `ChatViewModel`).
private struct ToolRoundBubbleView: View {
    let bubble: ChatBubble
    let verbose: Bool
    /// Invoked after the user toggles the disclosure so the parent ScrollView
    /// can scroll the bubble back into view on collapse — same rationale as
    /// `SystemBubbleView.onToggleExpansion`.
    let onToggleExpansion: (String) -> Void
    @State private var isExpanded: Bool = false

    private var entries: [ToolCallEntry] { bubble.toolEntries }
    private var failedCount: Int { entries.filter { $0.state == .failed }.count }
    private var pendingCount: Int { entries.filter { $0.state == .pending }.count }

    private var titleText: String {
        let n = entries.count
        if pendingCount > 0 {
            return "Calling \(n) tool\(n == 1 ? "" : "s")…"
        }
        if failedCount > 0 {
            return "Used \(n) tool\(n == 1 ? "" : "s") — \(failedCount) failed"
        }
        return "Used \(n) tool\(n == 1 ? "" : "s")"
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    withAnimation(.easeOut(duration: 0.2)) { isExpanded = newValue }
                    onToggleExpansion(bubble.id)
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entries) { entry in
                    entryRow(entry)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                statusIcon
                Text(titleText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if pendingCount > 0 {
            ProgressView().controlSize(.small)
        } else if failedCount > 0 {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ToolCallEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                entryStatusIcon(entry.state)
                Text(entry.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            if verbose && entry.state != .pending {
                if !entry.argsJSON.isEmpty {
                    verbosePayload(label: "args", body: entry.argsJSON)
                }
                if !entry.resultText.isEmpty {
                    verbosePayload(label: "result", body: entry.resultText)
                }
            }
        }
    }

    @ViewBuilder
    private func entryStatusIcon(_ state: ToolCallEntry.State) -> some View {
        switch state {
        case .pending:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func verbosePayload(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label):")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(body)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(.leading, 18)
    }
}

/// Floating list of matching slash commands shown above the chat TextField
/// while the user is typing a `/…` prefix. Tapping a row fills the draft with
/// `/<name> ` so the user can keep typing args (or just hit Send).
private struct SlashCommandPalette: View {
    let commands: [SlashCommand]
    let onPick: (String) -> Void

    var body: some View {
        if commands.isEmpty {
            HStack {
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("No matching commands. Type /help for the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.name) { cmd in
                    Button {
                        onPick(cmd.name)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("/\(cmd.name)")
                                .font(.callout.monospaced())
                                .foregroundStyle(.primary)
                            Text(cmd.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if cmd.name != commands.last?.name {
                        Divider().padding(.leading, 10)
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
    }
}

@ViewBuilder
private func attachmentThumbnail(_ data: Data) -> some View {
    #if canImport(UIKit)
    if let img = UIImage(data: data) {
        Image(uiImage: img).resizable().scaledToFill()
    } else {
        Color.gray.opacity(0.2)
    }
    #elseif canImport(AppKit)
    if let img = NSImage(data: data) {
        Image(nsImage: img).resizable().scaledToFill()
    } else {
        Color.gray.opacity(0.2)
    }
    #else
    Color.gray.opacity(0.2)
    #endif
}
