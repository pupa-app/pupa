import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MarkdownUI
#if os(iOS)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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

/// maxY of the message list's bottom marker, in the scroll view's coordinate
/// space. Compared against the viewport height to decide if we're at the bottom.
private struct ChatBottomMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

public struct ChatPanel: View {
    @Bindable var viewModel: ChatViewModel
    /// All conversation threads for the current scope, oldest-first. Drives the
    /// header thread-selector dropdown.
    let threads: [ChatThread]
    /// The id of the thread currently shown in this panel — checkmarked in the
    /// dropdown.
    let currentThreadId: String
    /// Called with a thread id when the user picks a different conversation
    /// from the dropdown.
    let onSelectThread: (String) -> Void
    /// Called when the user taps the `+` button to start a new conversation.
    let onAddThread: (() -> Void)?
    /// Called with a thread id when the user deletes a conversation. `nil`
    /// when only one thread exists (delete is not offered).
    let onDeleteThread: ((String) -> Void)?
    /// Live status for any thread id — drives the per-row dots in the dropdown
    /// and the aggregate badge on the collapsed dropdown label. Defaults to
    /// `.idle` (no badge) for previews / callers that don't wire it.
    let status: (String) -> ChatActivityStatus
    /// Model catalog for the header's per-thread model chip. Empty hides the
    /// chip (previews / callers that don't wire it).
    let modelOptions: [KnownLLMModel]
    /// Catalog id of the current thread's effective model — the thread override
    /// if pinned, else the scope default. Drives the chip's resting selection.
    let selectedModelId: String
    /// Called with a catalog model id when the user picks a model for the
    /// current thread. The backend-default sentinel clears the override.
    let onSelectModel: (String) -> Void
    @State private var showThreadList: Bool = false
    /// Shared guided-tour store. The chat / slash steps park a prefill in
    /// `chatPrefill`; we drop it into the composer so the coach card can point
    /// at a ready-to-send message (or surface the `SlashCommandPalette` on "/").
    @State private var tour = GuidedTourStore.shared
    /// In-flight typewriter task for a streamed tour prefill, cancelled when the
    /// panel disappears or the user starts typing.
    @State private var prefillTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Unsent composer content (`viewModel.draft` / `.draftImages`) is session
    // state, not `@State`: closing the overlay unmounts this panel, and the
    // user's typing must survive that. Same for `viewModel.streamedDraft`,
    // which only means anything paired with `draft`.
    /// Focus binding for the composer; lets a tap outside / scroll resign
    /// first responder so the iOS soft keyboard closes.
    @FocusState private var composerFocused: Bool
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoadingImage: Bool = false
    @State private var isDropTargeted: Bool = false
    /// Presents the system photo-library picker (driven by the paperclip menu).
    @State private var showPhotoPicker: Bool = false
    /// iOS attach action sheet (Photo Library / Take Photo). A bottom
    /// `confirmationDialog` instead of a `Menu` so it doesn't shove the
    /// bottom-anchored chat card up to fit an anchored popup menu.
    @State private var showAttachOptions: Bool = false
    #if os(iOS)
    /// Presents the in-app camera capture sheet (paperclip menu → Take Photo).
    @State private var showCameraSheet: Bool = false
    #endif
    /// Whether the newest message is currently on screen. Driven by the bottom
    /// marker vs the viewport (see the jump-button overlay). Gates the
    /// re-anchor triggers so height changes only stick the view to the bottom
    /// when the user is already there — never yanks someone reading history.
    @State private var isAtBottom: Bool = true
    /// Coordinate space + id for the message list's bottom marker, used to
    /// decide whether the newest message is on screen (see the jump button).
    private static let scrollSpaceName = "chatScroll"
    private static let bottomMarkerID = "chatBottomMarker"
    /// Slack (pt) within which "near the bottom" still counts as at-bottom, so
    /// the jump button doesn't flicker on the last sliver of scroll.
    private static let atBottomSlack: CGFloat = 40

    public init(
        viewModel: ChatViewModel,
        threads: [ChatThread] = [],
        currentThreadId: String = "",
        onSelectThread: @escaping (String) -> Void = { _ in },
        onAddThread: (() -> Void)? = nil,
        onDeleteThread: ((String) -> Void)? = nil,
        status: @escaping (String) -> ChatActivityStatus = { _ in .idle },
        modelOptions: [KnownLLMModel] = [],
        selectedModelId: String = "",
        onSelectModel: @escaping (String) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.threads = threads
        self.currentThreadId = currentThreadId
        self.onSelectThread = onSelectThread
        self.onAddThread = onAddThread
        self.onDeleteThread = onDeleteThread
        self.status = status
        self.modelOptions = modelOptions
        self.selectedModelId = selectedModelId
        self.onSelectModel = onSelectModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                  VStack(spacing: 0) {
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
                        if viewModel.isModelWorking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Working…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .id("modelWorkingSpinner")
                            .transition(.opacity)
                        }
                        switch viewModel.connectionIssue {
                        case .reconnecting:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Reconnecting…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .transition(.opacity)
                        case .failed(let message):
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                                .padding(.horizontal, 12)
                        case nil:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    // Clearance so the last message can scroll clear above the
                    // floating composer pill rather than sitting behind it.
                    .padding(.bottom, 64)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Zero-height marker at the true bottom of the content.
                    // Its position in the scroll space (vs the viewport height)
                    // tells us whether the newest message is on screen.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomMarkerID)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: ChatBottomMarkerKey.self,
                                value: geo.frame(in: .named(Self.scrollSpaceName)).maxY)
                        })
                  }
                  // Tap the message area (no scroll) → drop composer focus so
                  // the soft keyboard closes. `simultaneousGesture` so it does
                  // not swallow taps on interactive bubble content.
                  #if os(iOS)
                  .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                  #endif
                }
                // Start scrolling the messages → close the keyboard too.
                #if os(iOS)
                .scrollDismissesKeyboard(.immediately)
                #endif
                .coordinateSpace(.named(Self.scrollSpaceName))
                .defaultScrollAnchor(.bottom)
                // Fade messages into the card material as they pass behind the
                // floating composer. Mask (not a solid overlay) because the
                // card background is translucent `.regularMaterial`.
                .mask(scrollFadeMask)
                // A new message always pulls the view to the true content
                // bottom (the marker, past the clearance padding) — same anchor
                // the jump button uses, so the two paths agree.
                .onChange(of: viewModel.bubbles.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                    }
                }
                // Content height also changes WITHOUT a bubble-count change:
                // streaming text growing in the last bubble, and the
                // isModelWorking / connectionIssue status rows appearing or
                // disappearing (they live in the LazyVStack but aren't bubbles).
                // `defaultScrollAnchor(.bottom)` doesn't reliably re-pin a
                // LazyVStack on those, so without these triggers the offset
                // drifts into the trailing clearance and the viewport goes
                // blank. Re-anchor on each, gated on isAtBottom so we never
                // yank a user who scrolled up to read history.
                .onChange(of: viewModel.bubbles.last?.text.count ?? 0) { _, _ in
                    reanchorIfAtBottom(proxy)
                }
                .onChange(of: viewModel.isModelWorking) { _, _ in
                    reanchorIfAtBottom(proxy)
                }
                .onChange(of: viewModel.isStreaming) { _, _ in
                    reanchorIfAtBottom(proxy)
                }
                .onChange(of: viewModel.connectionIssue) { _, _ in
                    reanchorIfAtBottom(proxy)
                }
                // Opening a chat / switching threads: defaultScrollAnchor(.bottom)
                // positions once at first layout, but bubbles (Markdown, images,
                // code) measure asynchronously and grow AFTER that, leaving the
                // view stranded above the true bottom — the "open a chat, see
                // blank, scroll up" case. No streaming/count change fires here,
                // so force the pin explicitly. Deferred to the next runloop so
                // the marker exists and initial content has laid out; retried
                // once more to catch late async bubble sizing.
                .onAppear { pinToBottomAfterLayout(proxy) }
                .onChange(of: currentThreadId) { _, _ in
                    isAtBottom = true
                    pinToBottomAfterLayout(proxy)
                }
                // Floating "jump to latest" button — only while scrolled up.
                // Sits above the composer pill, trailing edge. Driven purely by
                // the bottom marker's position vs the viewport (declarative, no
                // state mutation), so it stays correct as content streams in.
                .overlayPreferenceValue(ChatBottomMarkerKey.self) { markerY in
                    GeometryReader { geo in
                        let atBottom = markerY <= geo.size.height + Self.atBottomSlack
                        Color.clear
                            .onAppear { isAtBottom = atBottom }
                            .onChange(of: atBottom) { _, v in isAtBottom = v }
                        if !atBottom {
                            scrollToBottomButton(proxy)
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: .bottomTrailing)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: markerY)
                }
                // Composer floats over the messages so the chat list uses the
                // full height; the mask above is applied first, so the pill
                // itself stays crisp.
                .overlay(alignment: .bottom) { inputBar }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardBackground)
        // This thread is on screen → never badge it as unviewed. Clear on
        // appear and again whenever a turn settles or errors while visible, so
        // the badge only ever shows for threads the user isn't reading.
        .onAppear { viewModel.markViewed() }
        .onChange(of: viewModel.isStreaming) { viewModel.markViewed() }
        .onChange(of: viewModel.connectionIssue) { viewModel.markViewed() }
        .onAppear {
            // First chat opened after onboarding: pre-fill the composer with a
            // suggested message so the user's first action is a single tap.
            // Consume-once, so ordinary chat opens are untouched.
            if viewModel.draft.isEmpty, !viewModel.isStreaming,
               let suggested = OnboardingHandoff.shared.consumeSuggestedPrompt() {
                viewModel.draft = suggested
            }
            // Guided tour: the chat step opens this overlay, so the prefill is
            // already parked before the panel mounts — type it in on appear.
            if let prefill = tour.chatPrefill, !prefill.isEmpty {
                streamPrefill(prefill)
            }
            consumeChatAutoSend()
        }
        // Guided tour with the overlay already open (the slash-commands step
        // toggling "/" while chat is up): adopt the prefill reactively so the
        // SlashCommandPalette surfaces without re-mounting the panel.
        .onChange(of: tour.chatPrefill) { _, prefill in
            if let prefill, !prefill.isEmpty {
                streamPrefill(prefill)
            }
        }
        // Notification `runAgent` tap: AppView parks the prompt here, we fire it
        // as a turn on this scope's viewModel. Reactive (overlay already open)
        // + the onAppear above (overlay just opened by the tap).
        .onChange(of: tour.chatAutoSend) { _, _ in consumeChatAutoSend() }
        .onDisappear { prefillTask?.cancel() }
    }

    /// Fire a parked `runAgent` prompt exactly once. Consume-BEFORE-send:
    /// `ChatPanel` remounts per chat scope, so a value surviving the send would
    /// re-fire against the next scope's viewModel.
    private func consumeChatAutoSend() {
        guard let prompt = tour.chatAutoSend, !prompt.isEmpty else { return }
        tour.chatAutoSend = nil
        viewModel.send(prompt)
    }

    /// Type a tour prefill into the composer with a brief lead-in then a
    /// character-by-character reveal, so the coach card's example looks typed
    /// rather than pasted. Reduce Motion (and single-char prefills like "/",
    /// which must surface the `SlashCommandPalette` at once) drop straight to
    /// the full string. Cancels any prior run and bails the moment the user
    /// starts typing, so a stream never fights real input.
    private func streamPrefill(_ text: String) {
        prefillTask?.cancel()
        // Replace an empty composer or our own previously-parked prefill; bail
        // the moment it holds something the user typed.
        guard viewModel.draft.isEmpty || viewModel.draft == viewModel.streamedDraft else { return }
        // A single-char prefill ("/" for the slash step) can't be "typed", but
        // still wait a beat so the composer is settled and the palette's appear
        // animation reads clearly rather than popping in on arrival.
        let isShort = text.count <= 1
        if reduceMotion && !isShort {
            viewModel.draft = text
            viewModel.streamedDraft = text
            return
        }
        prefillTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(isShort ? 300 : 400))
            // Re-check after the lead-in — the user may have started typing.
            guard !Task.isCancelled,
                  viewModel.draft.isEmpty || viewModel.draft == viewModel.streamedDraft else { return }
            if isShort {
                viewModel.draft = text
                viewModel.streamedDraft = text
                return
            }
            var typed = ""
            viewModel.draft = ""
            viewModel.streamedDraft = ""
            for ch in text {
                if Task.isCancelled || viewModel.draft != viewModel.streamedDraft { return }
                typed.append(ch)
                viewModel.draft = typed
                viewModel.streamedDraft = typed
                try? await Task.sleep(for: .milliseconds(24))
            }
        }
    }

    /// Force the view to the true content bottom after layout settles. Used on
    /// chat open / thread switch, where content grows asynchronously after the
    /// initial anchor. Two passes: one on the next runloop (marker exists,
    /// first pass of content laid out) and one slightly later to catch late
    /// async bubble sizing (Markdown / image measurement). Not gated on
    /// isAtBottom — opening a chat should always land at the newest message.
    private func pinToBottomAfterLayout(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            }
        }
    }

    /// Re-pin the view to the true content bottom, but only when the user is
    /// already at the bottom. Called from the height-change triggers (streaming
    /// growth, status rows) so those never strand the viewport in the trailing
    /// clearance, while leaving a scrolled-up reader undisturbed.
    private func reanchorIfAtBottom(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
        }
    }

    /// Floating pill that jumps the message list back to the newest message.
    /// Shown only when the user has scrolled up (see the bottom-marker overlay).
    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        // Clear the floating composer pill (its own bottom padding + height).
        .padding(.bottom, 76)
        .accessibilityLabel("Scroll to latest message")
    }

    /// Vertical alpha gradient masking the message ScrollView: fully opaque
    /// down to ~82% height, then fading to clear so messages dissolve into the
    /// translucent card behind the floating composer.
    private var scrollFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            threadDropdown
                .tourAnchor(.chatHeader)
            if !modelOptions.isEmpty {
                ModelPickerRow(
                    selectedId: selectedModelId,
                    options: modelOptions,
                    onSelect: onSelectModel,
                    compact: true
                )
            }
            Spacer()
            if let add = onAddThread {
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New conversation")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Conversation selector. Tapping the label opens a popover listing all
    /// threads newest-first. Tapping a thread row selects it and closes the
    /// popover. When 2+ threads exist a trash button sits at the right edge of
    /// each row; tapping it deletes that thread without closing the popover so
    /// multiple threads can be removed in one session.
    @ViewBuilder
    private var threadDropdown: some View {
        let currentTitle = threads.first(where: { $0.id == currentThreadId })?.title ?? ""
        // Fold the OTHER threads' statuses so a collapsed dropdown hints that a
        // conversation the user isn't reading needs attention.
        let otherStatus = threads
            .filter { $0.id != currentThreadId }
            .reduce(ChatActivityStatus.idle) { .max($0, status($1.id)) }
        Button { showThreadList = true } label: {
            HStack(spacing: 4) {
                Text(currentTitle.isEmpty ? "New chat" : currentTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if otherStatus != .idle {
                    StatusBadge(status: otherStatus, size: 11)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showThreadList) {
            threadListPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var threadListPopover: some View {
        let reversed = threads.reversed() as [ChatThread]
        // Long chat lists must scroll — the popover otherwise grows unbounded
        // and the oldest chats become unreachable. Cap the height and scroll
        // only when the content actually overflows.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(reversed.enumerated()), id: \.element.id) { idx, thread in
                    if idx > 0 { Divider() }
                    HStack(spacing: 0) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .opacity(thread.id == currentThreadId ? 1 : 0)
                            .frame(width: 28)
                        Button {
                            onSelectThread(thread.id)
                            showThreadList = false
                        } label: {
                            HStack(spacing: 6) {
                                Text(thread.title.isEmpty ? "New chat" : thread.title)
                                    .lineLimit(1)
                                let s = status(thread.id)
                                if s != .idle {
                                    StatusBadge(status: s, size: 12)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        if let onDeleteThread {
                            Button(role: .destructive) {
                                onDeleteThread(thread.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.75))
                                    .padding(.leading, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .frame(minWidth: 210, maxWidth: 300)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 400)
    }

    /// Floating, translucent composer pill. Anchored to the bottom of the
    /// message ScrollView as an overlay (not a layout row) so the chat list
    /// keeps the full height; only the pill is opaque, the rest is transparent
    /// so messages show through and fade behind it.
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prefix = activeSlashPrefix {
                SlashCommandPalette(
                    commands: viewModel.slashCommands.filter(prefix: prefix),
                    onPick: { name in
                        viewModel.draft = "/\(name) "
                    }
                )
            }
            if !viewModel.queuedMessages.isEmpty {
                queuedMessagesStack
            }
            if !viewModel.draftImages.isEmpty {
                attachmentPreviewRow
            } else if isDropTargeted {
                Text("Drop images to attach")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Button {
                    #if os(iOS)
                    showAttachOptions = true
                    #else
                    showPhotoPicker = true
                    #endif
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingImage || remainingImageSlots == 0)
                .help("Attach images — pick from your library or take a photo (or drag & drop onto the chat). Up to \(ChatViewModel.maxImagesPerMessage) per message.")
                #if os(iOS)
                .confirmationDialog("Attach image", isPresented: $showAttachOptions, titleVisibility: .hidden) {
                    Button("Photo Library") { showPhotoPicker = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo") { showCameraSheet = true }
                    }
                }
                #endif
                TextField(composerPlaceholder, text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .lineLimit(1...4)
                    // Typing stays enabled while streaming so the user can queue
                    // a follow-up; only a human-in-the-loop interrupt (answered
                    // via the bubble) gates the field.
                    .disabled(viewModel.isAwaitingHumanInput)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            sendDisabled ? Color.gray.opacity(0.4) : Color.accentColor,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.2),
                        lineWidth: isDropTargeted ? 2 : 0.5
                    )
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onChange(of: pickerItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            // Honour the remaining-slot budget at selection time; the picker's
            // own `maxSelectionCount` is a soft cap that can be exceeded when
            // combined with drops / camera captures already staged.
            let items = Array(newItems.prefix(remainingImageSlots))
            isLoadingImage = true
            Task {
                var prepared: [PickedImage] = []
                for item in items {
                    if let img = await loadPickedImage(from: item) { prepared.append(img) }
                }
                await MainActor.run {
                    self.viewModel.draftImages.append(contentsOf: prepared.prefix(self.remainingImageSlots))
                    self.isLoadingImage = false
                    self.pickerItems = []
                }
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickerItems,
            maxSelectionCount: ChatViewModel.maxImagesPerMessage,
            matching: .images,
            photoLibrary: .shared()
        )
        #if os(iOS)
        .sheet(isPresented: $showCameraSheet) {
            CameraPicker { data in
                showCameraSheet = false
                acceptCapturedImage(data)
            }
            .ignoresSafeArea()
        }
        #endif
    }

    #if os(iOS)
    /// Funnel a camera capture through the same prepare → `PickedImage` path as
    /// library picks and drag-and-drop, so the attachment preview / send flow
    /// is identical regardless of source.
    private func acceptCapturedImage(_ data: Data?) {
        guard let data, remainingImageSlots > 0 else { return }
        isLoadingImage = true
        Task {
            let prepared = ImagePreparer.prepare(data)
            await MainActor.run {
                if let prepared, self.remainingImageSlots > 0 {
                    self.viewModel.draftImages.append(PickedImage(data: prepared.data, mimeType: prepared.mimeType))
                }
                self.isLoadingImage = false
            }
        }
    }
    #endif

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        // Dropping images while streaming is fine — they attach to the message
        // the user is composing, which then queues. Take as many providers as
        // there are free slots.
        guard !isLoadingImage, remainingImageSlots > 0 else { return false }
        let accepted = providers.prefix(remainingImageSlots).filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !accepted.isEmpty else { return false }
        isLoadingImage = true
        Task {
            for provider in accepted {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    await acceptImageProvider(provider)
                } else {
                    await acceptFileURLProvider(provider)
                }
            }
            await MainActor.run { isLoadingImage = false }
        }
        return true
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
        guard remainingImageSlots > 0,
              let raw, let prepared = ImagePreparer.prepare(raw) else { return }
        viewModel.draftImages.append(PickedImage(data: prepared.data, mimeType: prepared.mimeType))
    }

    /// When the draft is a partial slash command (slash followed by zero or
    /// more word characters, no whitespace), return the substring after the
    /// slash so the palette can filter on it. Returns `nil` otherwise so the
    /// palette stays hidden — e.g. once the user types a space after the
    /// command name (entering "args" territory) or for plain text.
    private var activeSlashPrefix: String? {
        guard viewModel.draft.first == "/" else { return nil }
        let rest = viewModel.draft.dropFirst()
        if rest.contains(where: { $0.isWhitespace }) { return nil }
        if !rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { return nil }
        return String(rest)
    }

    private var sendDisabled: Bool {
        if viewModel.isAwaitingHumanInput { return true }  // resolve via the card, not the composer
        if viewModel.isStreaming { return false }  // tap = queue (has content) or Stop (empty)
        if isLoadingImage { return true }
        return viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty && viewModel.draftImages.isEmpty
    }

    /// Whether the composer has any submittable content (text or attached
    /// images). Drives the streaming-mode button: content → arrow-up (queue),
    /// empty → stop (cancel the turn).
    private var composerHasContent: Bool {
        !viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty || !viewModel.draftImages.isEmpty
    }

    /// Remaining attachment slots before the per-message image cap is hit.
    private var remainingImageSlots: Int {
        max(0, ChatViewModel.maxImagesPerMessage - viewModel.draftImages.count)
    }

    /// The button shows Stop only while streaming with nothing to send. With
    /// content typed mid-stream it becomes an arrow-up that queues the message.
    private var showsStopButton: Bool {
        viewModel.isStreaming && !viewModel.isAwaitingHumanInput && !composerHasContent
    }

    /// The TextField is disabled while a turn is in flight, so swap the
    /// placeholder so the lock state is self-explanatory and the user
    /// knows Stop is their only mid-turn action. When the agent is parked
    /// on an `ask_user_questions` interrupt the composer is gated too —
    /// answers travel through the bubble's Submit button, not the
    /// composer, so the placeholder explains where to reply.
    private var composerPlaceholder: String {
        // Interrupt copy wins over the streaming copy: while parked, the turn
        // is technically still in flight (`isStreaming == true`) but the user's
        // only action is on the bubble, not the composer.
        if viewModel.hasPendingShellApproval { return "Approve or deny the command above…" }
        if viewModel.hasPendingQuestion { return "Answer above and tap Submit…" }
        if viewModel.isStreaming { return "Type to queue for when this finishes…" }
        return "Type a message or /help…"
    }

    /// Pending-message pills shown above the composer while a turn is in
    /// flight. Each carries a clock glyph (not-yet-sent), the message text,
    /// and a ✕ to cancel it. Tapping the row pulls the text back into the
    /// composer for editing and removes it from the queue. They auto-send in
    /// order as the current turn settles (see `ChatViewModel.drainQueue`).
    private var queuedMessagesStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.queuedMessages) { queued in
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(queued.text.isEmpty ? "Image" : queued.text)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button {
                        viewModel.removeQueuedMessage(id: queued.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel this queued message")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { editQueuedMessage(queued) }
            }
        }
        .transition(.opacity)
    }

    /// Pull a queued message back into the composer to edit before it sends,
    /// removing it from the queue. If the composer already holds unsent text we
    /// don't clobber it — the tap is ignored so the user's current draft is safe.
    private func editQueuedMessage(_ queued: QueuedMessage) {
        guard viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.draft = queued.text
        viewModel.removeQueuedMessage(id: queued.id)
    }

    /// Horizontal strip of staged attachments, each with its own remove button.
    @ViewBuilder
    private var attachmentPreviewRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.draftImages.enumerated()), id: \.offset) { index, image in
                        attachmentThumbnailCell(image, at: index)
                    }
                }
                .padding(.horizontal, 2)
            }
            if viewModel.draftImages.count > 1 {
                Text("\(viewModel.draftImages.count)/\(ChatViewModel.maxImagesPerMessage) images")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private func attachmentThumbnailCell(_ image: PickedImage, at index: Int) -> some View {
        attachmentThumbnail(image.data)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button {
                    guard viewModel.draftImages.indices.contains(index) else { return }
                    viewModel.draftImages.remove(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.5))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .padding(2)
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
        // Parked on a human-in-the-loop interrupt: the composer is inert.
        // Resolution flows through the bubble's Approve / Deny / Submit — the
        // composer's Stop affordance would cancel the turn and orphan the
        // backend interrupt. Guarded here too so a stray keyboard return is a
        // no-op even if the button/field disabled state is ever bypassed.
        if viewModel.isAwaitingHumanInput { return }
        if viewModel.isStreaming {
            // Mid-stream: content typed → queue it (auto-sends when the turn
            // settles); empty composer → the button is Stop, so cancel.
            if composerHasContent {
                viewModel.send(viewModel.draft, images: viewModel.draftImages)
                clearComposer()
            } else {
                viewModel.cancel()
            }
            return
        }
        viewModel.send(viewModel.draft, images: viewModel.draftImages)
        clearComposer()
    }

    /// Empty the composer after a send. `streamedDraft` goes with it so a
    /// later tour prefill compares against a clean slate.
    private func clearComposer() {
        viewModel.draft = ""
        viewModel.draftImages = []
        viewModel.streamedDraft = ""
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
                    ForEach(Array(bubble.imagesData.enumerated()), id: \.offset) { _, data in
                        attachmentThumbnail(data)
                            .frame(maxWidth: 240, maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let snapshot = bubble.chartSnapshot {
                        ChatChartBubble(snapshot: snapshot)
                    }
                    if (!bubble.text.isEmpty || bubble.imagesData.isEmpty) && bubble.chartSnapshot == nil {
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
                                .textSelection(.enabled)
                        } else {
                            Text(bubble.text.isEmpty ? "…" : bubble.text)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .background(bubble.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contextMenu {
                    if !bubble.text.isEmpty {
                        Button {
                            ChatClipboard.copy(bubble.text)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
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
/// `ask_user_questions` backend tool. The backend is paused on an
/// interrupt; the user picks an option or types a custom reply per
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

    /// Cap the list at ~7 rows; longer lists scroll instead of overflowing off
    /// the top of the chat area (the palette grows upward from the composer).
    private let maxHeight: CGFloat = 260

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
            // `ViewThatFits` hugs the content when it's short and only falls
            // back to the scrollable copy when the list is taller than `maxHeight`
            // (a bare `ScrollView` is greedy and would leave empty space).
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
            .frame(maxHeight: maxHeight)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
    }

    private var rows: some View {
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
    }
}

/// Renders a frozen `ChatChartSnapshot` inside an assistant bubble: a title
/// row + the store-free `ChartView`. No resolver / store — the series are
/// already resolved (snapshotted at embed time by `embedComponent`).
private struct ChatChartBubble: View {
    let snapshot: ChatChartSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !snapshot.title.isEmpty {
                Text(snapshot.title)
                    .font(.headline)
            }
            ChartView(series: snapshot.series, kind: snapshot.kind)
                .frame(width: 280, height: 200)
        }
    }
}

/// Cross-platform clipboard write for the bubble "Copy" context-menu action.
enum ChatClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
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
