import SwiftUI

/// Slack canvas component view. Two panes: channel sidebar on the
/// left, message thread + composer on the right. Channel/message mutations
/// route through `MyAppStore`'s `slack*` mutators; agents are filesystem
/// subagents (`pupa/agents/`) surfaced via `agentRoster`.
///
/// @-mentioning an agent (or posting in a DM) spawns a subagent run via
/// `ChatSessionCoordinator.invokeSlackAgent`, streamed live into the channel
/// pane through `SlackInvoker`.
public struct SlackView: View {
    @Bindable var store: MyAppStore
    let data: SlackData
    let myAppId: UUID
    let componentId: String
    let coordinator: ChatSessionCoordinator
    @Bindable var invoker: SlackInvoker

    @State private var newChannelSheet: Bool = false
    @State private var newAgentSheet: Bool = false
    /// Bumped after the create-agent sheet writes a new AGENTS.md so the
    /// disk-read `agentRoster` recomputes and the sidebar shows it.
    @State private var rosterRefresh: Int = 0
    @State private var composerText: String = ""
    @State private var lastInvocationNote: String?
    /// Drives the channels+agents drawer on compact horizontal
    /// size classes (iPhone portrait). On regular widths the
    /// sidebar is always visible side-by-side and this state is
    /// unused.
    @State private var sidebarPresented: Bool = false

    /// Per-channel scroll restoration. Maps `channelId` → the id of
    /// the message (or bottom marker) we should anchor to the bottom
    /// of the viewport when re-entering that channel. Lives at the
    /// SlackView level so the inner ScrollView's `.id(channel.id)`
    /// rebuild on channel switch doesn't wipe it. Channels with no
    /// entry default to the bottom anchor — fresh visits land on the
    /// latest message.
    @State private var channelScrollAnchor: [String: String] = [:]

    /// True iff we're in a horizontally cramped environment
    /// (iPhone portrait). Drives the top-level layout switch —
    /// the 220pt sidebar is only used when there's room for it.
    /// macOS / iPad / landscape phones get the side-by-side
    /// layout regardless of window width.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    public init(
        store: MyAppStore,
        data: SlackData,
        myAppId: UUID,
        componentId: String,
        coordinator: ChatSessionCoordinator
    ) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
        self.coordinator = coordinator
        self.invoker = coordinator.slackInvoker
    }

    /// The MyApp's subagent roster — every `pupa/agents/<slug>/AGENTS.md`,
    /// re-read from disk each render. Slack agents ARE subagents now; the
    /// component holds no agent list of its own. `rosterRefresh` forces a
    /// recompute after the create-agent sheet writes a new file.
    private var agentRoster: [Subagent] {
        _ = rosterRefresh
        return AgentStore(memory: MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: myAppId))).agents
    }

    public var body: some View {
        Group {
            if isCompact {
                // Compact (iPhone portrait): single-pane —
                // message pane fills the width, sidebar slides
                // in as a sheet via the hamburger button in the
                // channel header.
                messagePane
            } else {
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                        .frame(width: 220)
                    Divider()
                    messagePane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minHeight: 480)
        .background(Color.gray.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Intercept `pupa-mention://<agentId>` URLs emitted
        // by the message-bubble AttributedString — open a DM with
        // the mentioned agent instead of handing the URL off to
        // the system browser. Any other URL falls through to the
        // default handler.
        .environment(\.openURL, OpenURLAction { [store, myAppId, componentId] url in
            guard url.scheme == Self.mentionURLScheme,
                  let agentId = url.host, !agentId.isEmpty else {
                return .systemAction
            }
            let display = AgentStore(memory: MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: myAppId)))
                .agent(named: agentId)?.displayName ?? agentId
            if let dmId = store.slackOpenDM(
                agentId: agentId,
                displayName: display,
                myAppId: myAppId,
                componentId: componentId
            ) {
                _ = store.slackSetActiveChannel(
                    channelId: dmId,
                    myAppId: myAppId,
                    componentId: componentId
                )
            }
            return .handled
        })
        #if os(iOS)
        .sheet(isPresented: $sidebarPresented) {
            // Picking a channel inside the drawer also dismisses
            // it — the existing `slackSetActiveChannel` mutator
            // is invoked from inside `sidebar`, so we just watch
            // for activeChannelId changes and close on transition.
            NavigationStack {
                sidebar
                    .navigationTitle("Slack")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { sidebarPresented = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: data.activeChannelId) { _, _ in
            // Auto-dismiss the drawer when the user picks a
            // different channel — they want to see the messages.
            if sidebarPresented { sidebarPresented = false }
        }
        #endif
        .sheet(isPresented: $newChannelSheet) {
            SlackChannelEditorSheet(
                agents: agentRoster,
                onCreate: { name, type, members in
                    _ = store.slackAddChannel(
                        name: name,
                        type: type,
                        memberAgentIds: members,
                        myAppId: myAppId,
                        componentId: componentId
                    )
                    newChannelSheet = false
                },
                onCancel: { newChannelSheet = false }
            )
        }
        .sheet(isPresented: $newAgentSheet) {
            SlackAgentEditorSheet(
                onCreate: { name, role, prompt in
                    // Create a filesystem subagent — the canonical writer
                    // produces pupa/agents/<slug>/AGENTS.md; `role` becomes the
                    // subagent description.
                    let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: myAppId))
                    _ = try? AgentStore(memory: appMemory).createAgent(
                        name: name,
                        description: role,
                        prompt: prompt
                    )
                    rosterRefresh += 1
                    newAgentSheet = false
                },
                onCancel: { newAgentSheet = false }
            )
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    channelSection(title: "Channels", type: .channel)
                    channelSection(title: "Group DMs", type: .groupDM)
                    channelSection(title: "Direct messages", type: .dm)
                    agentsSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
    }

    private var sidebarHeader: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Slack")
                .font(.headline)
            Spacer()
            Menu {
                Button("New channel…") { newChannelSheet = true }
                Button("New agent…") { newAgentSheet = true }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.06))
    }

    @ViewBuilder
    private func channelSection(title: String, type: SlackChannelType) -> some View {
        let channels = data.channels.filter { $0.type == type }
        if !channels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                ForEach(channels) { channel in
                    SidebarRow(
                        label: prefix(for: type) + channel.name,
                        glyph: glyph(for: type),
                        isActive: channel.id == data.activeChannelId,
                        onTap: {
                            _ = store.slackSetActiveChannel(
                                channelId: channel.id,
                                myAppId: myAppId,
                                componentId: componentId
                            )
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        if !agentRoster.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("AGENTS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                ForEach(agentRoster) { agent in
                    let label = agent.displayName ?? agent.name
                    Button {
                        let dmId = store.slackOpenDM(
                            agentId: agent.name,
                            displayName: label,
                            myAppId: myAppId,
                            componentId: componentId
                        )
                        if let dmId {
                            _ = store.slackSetActiveChannel(
                                channelId: dmId,
                                myAppId: myAppId,
                                componentId: componentId
                            )
                        }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label)
                                    .font(.subheadline)
                                    .foregroundStyle(SlackAgentPalette.color(forAgentId: agent.name))
                                if !agent.description.isEmpty {
                                    Text(agent.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if invoker.isBusy(agent.name) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open a DM with \(label)")
                }
            }
        }
    }

    private func prefix(for type: SlackChannelType) -> String {
        switch type {
        case .channel: return "# "
        case .groupDM, .dm: return ""
        }
    }

    private func glyph(for type: SlackChannelType) -> String {
        switch type {
        case .channel: return "number"
        case .groupDM: return "person.3"
        case .dm: return "person"
        }
    }

    // MARK: - Message pane

    @ViewBuilder
    private var messagePane: some View {
        if let channel = activeChannel {
            VStack(spacing: 0) {
                channelHeader(channel)
                Divider()
                messageList(channel)
                Divider()
                composer(channel)
            }
        } else {
            emptyState
        }
    }

    private var activeChannel: SlackChannel? {
        guard let id = data.activeChannelId else { return data.channels.first }
        return data.channels.first(where: { $0.id == id }) ?? data.channels.first
    }

    private func channelHeader(_ channel: SlackChannel) -> some View {
        HStack(spacing: 8) {
            if isCompact {
                Button {
                    sidebarPresented = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show channels and agents")
            }
            Image(systemName: glyph(for: channel.type))
                .foregroundStyle(.secondary)
            Text(channel.name)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(Self.memberCountLabel(channel.memberAgentIds.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Pluralised member count for the channel header — `"No
    /// members"`, `"1 member"`, `"N members"`. Static + pure so
    /// the unit test in `SlackMutatorsTests` can hit it without
    /// standing up the view.
    static func memberCountLabel(_ count: Int) -> String {
        switch count {
        case 0: return "No members"
        case 1: return "1 member"
        default: return "\(count) members"
        }
    }

    private func messageList(_ channel: SlackChannel) -> some View {
        let messages = (data.messagesByChannel[channel.id] ?? [])
            .sorted { $0.timestamp < $1.timestamp }
        let inflight = invoker.invocations(forChannel: channel.id)
        // Zero-height marker for "scroll all the way to the bottom".
        // A dedicated id (rather than the last message id) is robust
        // to ThinkingBubbles appearing/disappearing as agents start
        // and finish — they live above this marker too.
        let bottomAnchor = "slack-bottom"
        let channelId = channel.id

        // Two-way binding into `channelScrollAnchor`. Default value is
        // `bottomAnchor` so first-time visits open at the most recent
        // message. As the user scrolls, the binding updates with the
        // id of whatever is anchored at the viewport's bottom edge —
        // that's what we restore on the next visit.
        let scrollAnchorBinding = Binding<String?>(
            get: { channelScrollAnchor[channelId] ?? bottomAnchor },
            set: { newId in
                guard let newId else { return }
                channelScrollAnchor[channelId] = newId
            }
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty && inflight.isEmpty {
                    Text("No messages yet. Type below to start the conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(messages) { msg in
                        MessageBubble(
                            message: msg,
                            authorName: authorName(for: msg),
                            authorColor: authorColor(for: msg),
                            attributedText: Self.attributedMessageText(msg.text, agents: agentRoster)
                        )
                        .id(msg.id)
                    }
                    ForEach(inflight, id: \.agentId) { state in
                        ThinkingBubble(state: state)
                            .id("inflight-thinking-\(state.agentId)")
                        if state.pendingQuestion != nil {
                            SlackQuestionBubble(invoker: invoker, state: state)
                                .id("inflight-question-\(state.agentId)")
                        }
                        if state.pendingShellApproval != nil {
                            SlackShellApprovalBubble(invoker: invoker, state: state)
                                .id("inflight-shell-\(state.agentId)")
                        }
                    }
                }
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition(id: scrollAnchorBinding, anchor: .bottom)
        .id(channelId)
        .frame(maxHeight: .infinity)
    }

    private func authorName(for msg: SlackMessage) -> String {
        switch msg.authorKind {
        case .user: return "You"
        case .agent:
            let a = agentRoster.first(where: { $0.name == msg.authorId })
            return a?.displayName ?? a?.name ?? msg.authorId
        }
    }

    private func authorColor(for msg: SlackMessage) -> Color {
        switch msg.authorKind {
        case .user: return .primary
        case .agent: return SlackAgentPalette.color(forAgentId: msg.authorId)
        }
    }

    private func composer(_ channel: SlackChannel) -> some View {
        VStack(spacing: 0) {
            if let note = lastInvocationNote {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { lastInvocationNote = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }
            // Mention palette — floats above the input when an
            // `@<partial>` token is being typed. Click to insert.
            if let token = activeMentionToken {
                let matches = mentionMatches(token.partial)
                if !matches.isEmpty {
                    MentionPalette(
                        agents: matches,
                        onPick: { agent in
                            applyMention(agent, token: token)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }
            HStack(spacing: 8) {
                TextField(composerPlaceholder(for: channel, compact: isCompact), text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { send(in: channel) }
                Button {
                    send(in: channel)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .fixedSize()
                .help("Send")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.06))
        }
    }

    // MARK: - @mention autofill

    /// One in-flight `@<partial>` token in the composer. `range`
    /// covers the `@` plus everything typed after it, so picking
    /// an agent replaces the token cleanly with `@<name> `.
    /// `internal` so unit tests can construct + inspect tokens
    /// without going through the live composer state.
    struct ActiveMentionToken: Equatable {
        let range: Range<String.Index>
        let partial: String
    }

    /// Resolve the active mention token (if any) at the trailing
    /// edge of `composerText`. A token is the last `@` that's
    /// either at start-of-string or preceded by whitespace,
    /// followed by zero or more name-charset characters to the
    /// end of the string. Returning nil dismisses the palette.
    private var activeMentionToken: ActiveMentionToken? {
        Self.activeMentionToken(in: composerText)
    }

    /// Public for unit-test access; the composer's `activeMentionToken`
    /// is the only runtime caller.
    static func activeMentionToken(in text: String) -> ActiveMentionToken? {
        guard let atIdx = text.lastIndex(of: "@") else { return nil }
        if atIdx != text.startIndex {
            let prev = text.index(before: atIdx)
            if !text[prev].isWhitespace { return nil }
        }
        let after = text.index(after: atIdx)
        let partial = String(text[after..<text.endIndex])
        guard partial.allSatisfy({
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "."
        }) else { return nil }
        return ActiveMentionToken(range: atIdx..<text.endIndex, partial: partial)
    }

    /// Subagents whose slug or display name has `partial` as a prefix
    /// (case-insensitive). Empty partial returns every agent.
    private func mentionMatches(_ partial: String) -> [Subagent] {
        if partial.isEmpty { return agentRoster }
        let q = partial.lowercased()
        return agentRoster.filter {
            $0.name.lowercased().hasPrefix(q) || ($0.displayName?.lowercased().hasPrefix(q) ?? false)
        }
    }

    /// Replace the active `@<partial>` with `@<slug> ` and dismiss the
    /// palette via the trailing space. The slug (no spaces) is the stable
    /// mention token `parseMentions` resolves.
    private func applyMention(_ agent: Subagent, token: ActiveMentionToken) {
        composerText.replaceSubrange(token.range, with: "@\(agent.name) ")
    }

    /// DM composer drops the `@mention` hint — in a 1-on-1 DM the
    /// recipient is implicit, so every user post auto-invokes them.
    /// `compact` suppresses the "use @name to mention" hint on
    /// narrow horizontal layouts (iPhone portrait) where it would
    /// truncate to `Mes…` anyway; the `@`-autofill palette covers
    /// discoverability.
    private func composerPlaceholder(for channel: SlackChannel) -> String {
        composerPlaceholder(for: channel, compact: isCompact)
    }

    private func composerPlaceholder(for channel: SlackChannel, compact: Bool) -> String {
        Self.composerPlaceholder(for: channel, agents: agentRoster, compact: compact)
    }

    /// Pure helper for unit tests. Returns the user-facing
    /// placeholder string given the channel, the known agent roster,
    /// and the layout density.
    static func composerPlaceholder(
        for channel: SlackChannel,
        agents: [Subagent],
        compact: Bool
    ) -> String {
        if channel.type == .dm, let agentId = channel.memberAgentIds.first,
           let agent = agents.first(where: { $0.name == agentId }) {
            return "Message @\(agent.displayName ?? agent.name)"
        }
        let prefix = channel.type == .channel ? "#" : ""
        let base = "Message \(prefix)\(channel.name)"
        return compact ? base : "\(base) — use @name to mention"
    }

    private func send(in channel: SlackChannel) {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let roster = agentRoster
        let explicitMentions = Self.parseMentions(text: trimmed, agents: roster)
        // DM auto-trigger: in a 1-on-1 DM, every user post invokes
        // the recipient agent even without an explicit `@mention`.
        // Channels + group DMs still require explicit mentions.
        let resolvedMentions: [String]
        if channel.type == .dm,
           explicitMentions.isEmpty,
           let agentId = channel.memberAgentIds.first {
            resolvedMentions = [agentId]
        } else {
            resolvedMentions = explicitMentions
        }
        _ = store.slackPostMessage(
            channelId: channel.id,
            authorKind: .user,
            authorId: "user",
            text: trimmed,
            mentionedAgentIds: resolvedMentions,
            myAppId: myAppId,
            componentId: componentId
        )
        composerText = ""
        lastInvocationNote = nil
        guard !resolvedMentions.isEmpty else { return }
        let channelId = channel.id
        let myAppId = myAppId
        let componentId = componentId
        let coordinator = coordinator
        let agentNamesById = Dictionary(
            uniqueKeysWithValues: roster.map { ($0.name, $0.displayName ?? $0.name) }
        )
        for agentId in resolvedMentions {
            Task { @MainActor in
                let outcome = await coordinator.invokeSlackAgent(
                    agentId: agentId,
                    channelId: channelId,
                    myAppId: myAppId,
                    componentId: componentId,
                    // A person typed the @-mention — no agent to credit.
                    caller: .user
                )
                let displayName = agentNamesById[agentId] ?? agentId
                switch outcome {
                case .completed:
                    lastInvocationNote = nil
                case .reentrant(let targetName):
                    lastInvocationNote = "@\(targetName) is currently waiting on another agent — try again once they finish."
                case .busy(let targetName):
                    lastInvocationNote = "@\(targetName) is already replying — wait for that turn to finish."
                case .maxDepthExceeded(let targetName, let depth):
                    lastInvocationNote = "@\(targetName) blocked — agent chain already \(depth) deep (limit \(coordinator.agentInvocationGate.maxChainDepth)). Agents stopped invoking each other to avoid a loop."
                case .budgetExhausted(let targetName, let exhaustedAfter):
                    lastInvocationNote = "@\(targetName) turn budget exhausted after \(exhaustedAfter) turns. Start a new session to re-engage."
                case .failed(let error):
                    lastInvocationNote = "@\(displayName) failed: \(error)"
                }
            }
        }
    }

    /// One `@AgentName` occurrence in a message text. Carries the
    /// substring range (so the renderer can decorate it), the
    /// resolved `SlackAgent.id` (so the tap handler knows which
    /// agent to open a DM with), and the agent name as authored.
    public struct MessageMention: Equatable, Sendable {
        public let range: Range<String.Index>
        public let agentId: String
        public let agentName: String
    }

    /// Locate every `@AgentName` occurrence in `text`. Unlike
    /// `parseMentions` (which dedups and returns ids only for the
    /// composer fan-out), this preserves every occurrence with
    /// its source range — the message renderer styles each
    /// occurrence independently and links each one to the right
    /// agent. Case-insensitive name match; unknown names are
    /// skipped.
    public nonisolated static func mentions(in text: String, agents: [Subagent]) -> [MessageMention] {
        var byName: [String: Subagent] = [:]
        for a in agents {
            byName[a.name.lowercased()] = a
            if let d = a.displayName { byName[d.lowercased()] = a }
        }
        var out: [MessageMention] = []
        let pattern = #"@([A-Za-z0-9._\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let nsName = ns.substring(with: match.range(at: 1))
            guard let agent = byName[nsName.lowercased()] else { return }
            if let swiftRange = Range(match.range, in: text) {
                out.append(MessageMention(
                    range: swiftRange,
                    agentId: agent.name,
                    agentName: agent.displayName ?? agent.name
                ))
            }
        }
        return out
    }

    /// Build the attributed body of one message. First parses
    /// `text` as inline-only markdown via Apple's native
    /// `AttributedString(markdown:options:)` so `**bold**`,
    /// `_italic_`, `` `code` `` and `[label](url)` render as
    /// rich text inside the chat bubble (block-level markdown is
    /// suppressed — bubbles stay single-paragraph). Then every
    /// resolved `@AgentName` substring is re-detected against the
    /// **parsed plain string** (markdown syntax characters like
    /// `**` have been stripped, so source-text offsets no longer
    /// line up) and overlaid with the accent color + a
    /// `pupa-mention://<agentId>` URL. The outer
    /// `SlackView.body` installs an `OpenURLAction` environment
    /// override that intercepts the scheme and routes to
    /// `slackOpenDM`. Malformed markdown falls back to plain text
    /// so a bad message still renders. Pure for unit-test
    /// friendliness.
    public nonisolated static func attributedMessageText(
        _ text: String,
        agents: [Subagent]
    ) -> AttributedString {
        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            attributed = AttributedString(text)
        }
        let plain = String(attributed.characters)
        for mention in mentions(in: plain, agents: agents) {
            let lowerOffset = plain.distance(from: plain.startIndex, to: mention.range.lowerBound)
            let upperOffset = plain.distance(from: plain.startIndex, to: mention.range.upperBound)
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: lowerOffset)
            let upper = attributed.index(attributed.startIndex, offsetByCharacters: upperOffset)
            let attrRange = lower..<upper
            attributed[attrRange].foregroundColor = .accentColor
            attributed[attrRange].link = URL(string: Self.mentionURLScheme + "://" + mention.agentId)
        }
        return attributed
    }

    /// Custom URL scheme used to encode mention taps inside the
    /// message-bubble `AttributedString`. `SlackView` installs an
    /// `OpenURLAction` that intercepts URLs with this scheme and
    /// routes them through `slackOpenDM` instead of handing them
    /// off to the system. Public so tests can refer to it.
    public nonisolated static let mentionURLScheme = "pupa-mention"

    /// Resolve every `@name` token in `text` against the component's
    /// agents list (case-insensitive exact match). Order-preserving,
    /// deduplicated. Pure function — safe to call from any actor
    /// context (the Slack tool handlers on the agent side call it
    /// off the main actor).
    public nonisolated static func parseMentions(text: String, agents: [Subagent]) -> [String] {
        var byName: [String: String] = [:]
        for a in agents {
            byName[a.name.lowercased()] = a.name
            if let d = a.displayName { byName[d.lowercased()] = a.name }
        }
        var out: [String] = []
        var seen = Set<String>()
        // Match `@` followed by a run of name characters. Names that
        // contain spaces aren't supported in v1 — the convention is
        // single-token agent names (marketing, dev, research).
        let pattern = #"@([A-Za-z0-9._\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            if let id = byName[name], seen.insert(id).inserted {
                out.append(id)
            }
        }
        return out
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No channel selected")
                .font(.headline)
            Text("Create a channel from the + button in the sidebar to start a conversation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let label: String
    let glyph: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(label)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: SlackMessage
    let authorName: String
    let authorColor: Color
    /// Pre-built attributed string with `@AgentName` runs tinted
    /// and linked to a `pupa-mention://<agentId>` URL. The
    /// enclosing `SlackView` intercepts those URLs to open a DM.
    let attributedText: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(authorColor)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(attributedText)
                .font(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Mention palette

/// Floating list of matching agents shown above the composer while
/// the user is typing a `@<partial>` token. Tapping a row replaces
/// the active token with `@<full-name> ` and dismisses the palette.
/// Mirrors the slash-command palette pattern in `ChatPanel`.
private struct MentionPalette: View {
    let agents: [Subagent]
    let onPick: (Subagent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(agents) { agent in
                Button {
                    onPick(agent)
                } label: {
                    HStack(spacing: 8) {
                        Text("@\(agent.name)")
                            .font(.callout.monospaced())
                            .foregroundStyle(SlackAgentPalette.color(forAgentId: agent.name))
                        if !agent.description.isEmpty {
                            Text(agent.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if agent.id != agents.last?.id {
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
        .frame(maxWidth: 360, alignment: .leading)
    }
}

// MARK: - Thinking bubble

/// Live per-agent "thinking…" card rendered in the channel while
/// an invocation is in flight. Mirrors the chat panel's
/// `ToolRoundBubbleView` look (status pill + tool-name list +
/// per-row spinner / checkmark / x) but scoped to one agent at a
/// time. Multiple bubbles stack when several agents are running
/// concurrently.
private struct ThinkingBubble: View {
    let state: SlackInvocationState

    private var pendingCount: Int { state.toolEntries.filter { $0.state == .pending }.count }
    private var failedCount: Int { state.toolEntries.filter { $0.state == .failed }.count }

    private var headerSuffix: String {
        let n = state.toolEntries.count
        if n == 0 { return " is thinking…" }
        if pendingCount > 0 { return " calling \(n) tool\(n == 1 ? "" : "s")…" }
        if failedCount > 0 { return " used \(n) tool\(n == 1 ? "" : "s") — \(failedCount) failed" }
        return " used \(n) tool\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                (Text(state.agentName)
                    .foregroundStyle(SlackAgentPalette.color(forAgentId: state.agentId))
                + Text(headerSuffix)
                    .foregroundStyle(.secondary))
                .font(.caption.monospaced())
                Spacer(minLength: 0)
            }
            if !state.toolEntries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.toolEntries) { entry in
                        HStack(spacing: 6) {
                            statusIcon(for: entry.state)
                            Text(entry.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SlackAgentPalette.color(forAgentId: state.agentId).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SlackAgentPalette.color(forAgentId: state.agentId).opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(for status: ToolCallEntry.State) -> some View {
        switch status {
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
}

/// Inline yellow question card rendered when a Slack sub-agent's
/// `ask_user_questions` call is parked. Mirrors the main chat's
/// `HumanQuestionBubbleView` but lives in the channel pane and routes
/// writes through `SlackInvoker.setPendingAnswer` / `submitAnswers` /
/// `cancelQuestion` keyed by `state.agentId`. Multiple bubbles stack
/// if more than one sub-agent is parked on a question in the same
/// channel concurrently.
private struct SlackQuestionBubble: View {
    @Bindable var invoker: SlackInvoker
    let state: SlackInvocationState

    var body: some View {
        if let question = state.pendingQuestion {
            content(question: question)
        }
    }

    @ViewBuilder
    private func content(question: SlackPendingQuestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.yellow)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 12) {
                Text("\(state.agentName) is asking")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                ForEach(Array(question.rows.enumerated()), id: \.offset) { rowIdx, row in
                    questionRow(rowIdx: rowIdx, row: row, currentAnswer: answer(at: rowIdx, question: question))
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        invoker.cancelQuestion(agentId: state.agentId)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        invoker.submitAnswers(agentId: state.agentId)
                    } label: {
                        Text("Submit")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!invoker.pendingAnswersComplete(agentId: state.agentId))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.yellow.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answer(at rowIdx: Int, question: SlackPendingQuestion) -> String {
        question.answers.indices.contains(rowIdx) ? question.answers[rowIdx] : ""
    }

    @ViewBuilder
    private func questionRow(rowIdx: Int, row: HumanQuestionRow, currentAnswer: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.question)
                .italic()
                .textSelection(.enabled)
            if row.options.isEmpty {
                TextField(
                    "Type a reply…",
                    text: Binding(
                        get: { currentAnswer },
                        set: { invoker.setPendingAnswer(agentId: state.agentId, rowIndex: rowIdx, value: $0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            } else {
                ForEach(Array(row.options.enumerated()), id: \.offset) { optIdx, option in
                    optionButton(rowIdx: rowIdx, optIdx: optIdx, option: option, isSelected: currentAnswer == option)
                }
            }
        }
    }

    @ViewBuilder
    private func optionButton(rowIdx: Int, optIdx: Int, option: String, isSelected: Bool) -> some View {
        Group {
            if isSelected {
                Button {
                    invoker.setPendingAnswer(agentId: state.agentId, rowIndex: rowIdx, value: option)
                } label: {
                    optionLabel(optIdx: optIdx, option: option, isSelected: true)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    invoker.setPendingAnswer(agentId: state.agentId, rowIndex: rowIdx, value: option)
                } label: {
                    optionLabel(optIdx: optIdx, option: option, isSelected: false)
                }
                .buttonStyle(.bordered)
            }
        }
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
}

/// Inline shell-command approval card shown when a sub-agent's
/// `ShellApprovalMiddleware` pauses before execution. Approve / Deny
/// route through `SlackInvoker.approveShellCommand` / `denyShellCommand`.
private struct SlackShellApprovalBubble: View {
    @Bindable var invoker: SlackInvoker
    let state: SlackInvocationState

    @State private var remember: Bool = false

    var body: some View {
        if let approval = state.pendingShellApproval {
            content(approval: approval)
        }
    }

    @ViewBuilder
    private func content(approval: SlackPendingShellApproval) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                Text("\(state.agentName) wants to run a command")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(approval.command)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Always allow this session", isOn: $remember)
                    .font(.caption)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Deny") {
                        invoker.denyShellCommand(agentId: state.agentId)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        invoker.approveShellCommand(agentId: state.agentId, remember: remember)
                    } label: {
                        Text("Approve")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
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

// MARK: - Agent color palette

/// Deterministic per-agent color picker. Same `agentId` always maps
/// to the same palette entry; different ids spread across an
/// 8-colour palette via a stable hash. Shared between the sidebar
/// agent dot and the message-bubble author label so an agent always
/// reads as the same colour everywhere it appears.
public enum SlackAgentPalette {
    public static let palette: [Color] = [
        .blue, .green, .orange, .pink,
        .purple, .red, .teal, .indigo,
    ]

    public static func color(forAgentId id: String) -> Color {
        // DJB2 hash — stable across runs (no per-process salt), keeps
        // the colour assignment deterministic between launches.
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - New channel sheet

private struct SlackChannelEditorSheet: View {
    let agents: [Subagent]
    let onCreate: (String, SlackChannelType, [String]) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var type: SlackChannelType = .channel
    @State private var selectedMembers: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. planning", text: $name)
                }
                Section("Type") {
                    Picker("Type", selection: $type) {
                        Text("Channel").tag(SlackChannelType.channel)
                        Text("Group DM").tag(SlackChannelType.groupDM)
                        Text("DM").tag(SlackChannelType.dm)
                    }
                    .pickerStyle(.segmented)
                }
                if !agents.isEmpty {
                    Section("Members") {
                        ForEach(agents) { agent in
                            Toggle(agent.displayName ?? agent.name, isOn: Binding(
                                get: { selectedMembers.contains(agent.name) },
                                set: { isOn in
                                    if isOn { selectedMembers.insert(agent.name) }
                                    else { selectedMembers.remove(agent.name) }
                                }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("New channel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, type, Array(selectedMembers))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 420)
            #endif
        }
    }
}

// MARK: - New agent sheet

private struct SlackAgentEditorSheet: View {
    let onCreate: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var role: String = ""
    @State private var systemPromptAddition: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. marketing", text: $name)
                }
                Section("Role") {
                    TextField("Short description", text: $role)
                }
                Section("System prompt addition") {
                    TextField("Persona text", text: $systemPromptAddition, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("New agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, role, systemPromptAddition)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 420)
            #endif
        }
    }
}
