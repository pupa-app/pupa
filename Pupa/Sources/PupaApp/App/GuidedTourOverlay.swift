import SwiftUI

/// The floating coach card for the guided tour. It narrates the active step
/// while the tour programmatically navigates the *real* app to the matching
/// surface (handled by `AppView.applyTourStep()` + the intent-flag reconcilers
/// in the host views) — so this view is pure presentation: counter, title,
/// body, and Back / Next (→ Finish) / Skip controls.
///
/// It positions itself by `step.placement` (top or bottom edge) and stays
/// leading-aligned so a bottom card never collides with the chat overlay's
/// bottom-trailing corner. Spacers — not a full-screen scrim — do the
/// positioning, so the app behind the card stays interactive. Rendered at two
/// sites (the `AppView` detail `ZStack` and, during the Settings step, the
/// `SettingsSheet` overlay) that both read the one shared store.
struct GuidedTourView: View {
    @Bindable var tour: GuidedTourStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let step = tour.currentStep {
            VStack(spacing: 0) {
                if step.placement == .bottom { Spacer(minLength: 0) }
                HStack(spacing: 0) {
                    card(step)
                        .frame(maxWidth: 380)
                    Spacer(minLength: 0)
                }
                if step.placement == .top { Spacer(minLength: 0) }
            }
            .padding(20)
            .transition(reduceMotion
                ? .opacity
                : .move(edge: step.placement == .top ? .top : .bottom).combined(with: .opacity))
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85),
                       value: tour.index)
        }
    }

    private func card(_ step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Text(step.body)
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
                    .tint(.orchestratorColor)
            }
        }
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orchestratorColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 6)
    }
}
