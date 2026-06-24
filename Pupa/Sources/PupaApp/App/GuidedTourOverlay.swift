import SwiftUI

/// The floating coach card for the guided tour. It narrates the active step
/// while the tour programmatically navigates the *real* app to the matching
/// surface (handled by `AppView.applyTourStep()` + the intent-flag reconcilers
/// in the host views) — so this view is pure presentation: counter, title,
/// body, and Back / Next (→ Finish) / Skip controls.
///
/// Each step starts the card at its designed spot (`step.placement`, top or
/// bottom edge, leading-aligned so a bottom card never collides with the chat
/// overlay's bottom-trailing corner), but the user can **drag it anywhere** via
/// the grab handle — handy when it sits over something they want to see. The
/// position resets to the step's anchor whenever the step changes. Spacers — not
/// a full-screen scrim — do the positioning, so the app behind the card stays
/// interactive. Rendered at two sites (the `AppView` ZStack and, during the
/// Settings steps, the `SettingsSheet` overlay) that both read the one shared
/// store.
struct GuidedTourView: View {
    @Bindable var tour: GuidedTourStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Committed drag offset from the step's anchor position. Reset to `.zero`
    /// when the step changes, so each step re-centres on its designed spot.
    @State private var dragOffset: CGSize = .zero
    /// Live translation while a drag is in progress; auto-resets on release.
    @GestureState private var activeDrag: CGSize = .zero

    var body: some View {
        if let step = tour.currentStep {
            VStack(spacing: 0) {
                if step.placement == .bottom { Spacer(minLength: 0) }
                HStack(spacing: 0) {
                    card(step)
                        .frame(maxWidth: 380)
                        .offset(
                            x: dragOffset.width + activeDrag.width,
                            y: dragOffset.height + activeDrag.height
                        )
                    Spacer(minLength: 0)
                }
                if step.placement == .top { Spacer(minLength: 0) }
            }
            .padding(20)
            // A bottom card ringing the bottom bar would otherwise sit right on
            // top of the ring — and the control it points at. Lift it clear so
            // the highlight stays visible and the user can actually tap the tab.
            .padding(.bottom, bottomLift(for: step))
            .onChange(of: tour.index) { _, _ in
                // New step → snap back to its designed anchor.
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = .zero
                }
            }
            .transition(reduceMotion
                ? .opacity
                : .move(edge: step.placement == .top ? .top : .bottom).combined(with: .opacity))
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
                       value: tour.index)
        }
    }

    /// Extra bottom inset for a bottom-anchored card so it sits clear of the
    /// bottom bar — and, when the step rings a bar tab, clear of the glow ring
    /// too. Lifts every bottom card off the very edge; zero for top cards.
    private func bottomLift(for step: TourStep) -> CGFloat {
        guard step.placement == .bottom else { return 0 }
        return MyAppBottomBar.rowHeight + MyAppBottomBar.verticalPadding * 2 + 28
    }

    private func card(_ step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            grabHandle
            HStack {
                Text("\(tour.index + 1) of \(tour.steps.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { tour.skip() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Skip tour")
            }
            Text(step.title)
                .font(.headline)
            Text((try? AttributedString(markdown: step.body)) ?? AttributedString(step.body))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if !tour.isFirstStep {
                    Button("Back") { tour.back() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(tour.isLastStep ? "Finish" : "Next") { tour.next() }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandColor)
            }
        }
        .padding(16)
        .background(Color.brandSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.brandColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 6)
    }

    /// A sheet-style grabber. Dragging it repositions the whole card; the rest
    /// of the card stays tappable so Back / Next / Skip keep working. Confined
    /// to the handle so the drag never competes with the buttons.
    private var grabHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .padding(.bottom, 2)
            .gesture(
                DragGesture()
                    .updating($activeDrag) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        dragOffset.width += value.translation.width
                        dragOffset.height += value.translation.height
                    }
            )
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            #endif
            .accessibilityLabel("Drag to move this tip")
    }
}
