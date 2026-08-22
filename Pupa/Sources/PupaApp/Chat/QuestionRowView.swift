import SwiftUI

/// One row of an `ask_user_questions` card: the question, its tappable
/// options, an "Other…" affordance, and the inline free-text field.
///
/// Shared by the chat transcript's `HumanQuestionBubbleView` and the Slack
/// pane's `SlackQuestionBubble` so the two cards can't drift apart.
///
/// Selection is driven entirely by `answer.choice` — an option index or
/// free text. Nothing here compares the typed text against the option
/// strings, so typing an option's exact wording stays the user's own answer
/// and duplicate option strings select independently.
struct QuestionRowView: View {
    let row: HumanQuestionRow
    let answer: PendingAnswer
    /// False for a historic card kept in the transcript for context: every
    /// control renders read-only.
    let isLive: Bool
    let onIntent: (QuestionAnswerIntent) -> Void

    /// Focus for the free-text field so tapping "Other…" lands the caret in
    /// one tap. Lives here rather than on the card because each row owns at
    /// most one field.
    @FocusState private var otherFocused: Bool

    /// Free text is showing when the row has no options at all, or when the
    /// user chose "Other…".
    private var showingOther: Bool {
        row.options.isEmpty || answer.choice == .other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.question)
                .italic()
                .textSelection(.enabled)
            if !row.options.isEmpty {
                ForEach(Array(row.options.enumerated()), id: \.offset) { optIdx, option in
                    optionButton(optIdx: optIdx, option: option)
                }
                otherButton
            }
            if showingOther { inlineTextField }
        }
        // Focus is requested here rather than in the "Other…" action: at the
        // moment of the tap the field doesn't exist yet, so the request has
        // nothing to bind to. By the time `choice` has changed it does.
        // Option-less rows are excluded so a card never opens the keyboard on
        // its own.
        .onChange(of: answer.choice) { _, choice in
            guard isLive, !row.options.isEmpty, choice == .other else { return }
            otherFocused = true
        }
    }

    private var otherButton: some View {
        let isSelected = answer.choice == .other
        return Button {
            onIntent(.chooseOther)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Other…")
                    .italic()
                    .foregroundStyle(.secondary)
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
        .buttonStyle(.bordered)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                : nil
        )
        .disabled(!isLive)
    }

    @ViewBuilder
    private func optionButton(optIdx: Int, option: String) -> some View {
        // Selected options use `.borderedProminent` (filled) and unselected
        // use `.bordered` (outline). Styled via a conditional Group rather
        // than a type-erased ButtonStyle because the system bordered styles
        // are `PrimitiveButtonStyle`, which doesn't compose with a generic
        // ButtonStyle wrapper.
        let isSelected = answer.choice == .option(optIdx)
        Group {
            if isSelected {
                Button { onIntent(.pickOption(optIdx)) } label: { optionLabel(optIdx: optIdx, option: option, isSelected: true) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { onIntent(.pickOption(optIdx)) } label: { optionLabel(optIdx: optIdx, option: option, isSelected: false) }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(!isLive)
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

    private var inlineTextField: some View {
        TextField(
            row.options.isEmpty ? "Type a reply…" : "Type a custom reply…",
            text: Binding(
                get: { answer.text },
                set: { onIntent(.typeOther($0)) }
            ),
            axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...3)
        .focused($otherFocused)
        .disabled(!isLive)
    }
}
