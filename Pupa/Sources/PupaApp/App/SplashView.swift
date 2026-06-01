import SwiftUI

/// Brief animated brand splash shown on every cold launch (see `RootView`).
/// The bundled `AppIcon` scales + fades in over a purple brand gradient, holds
/// for a beat, then `RootView` fades the whole view out. Tapping anywhere skips
/// straight to the app. Honors Reduce Motion by dropping the scale/spring for a
/// plain fade.
struct SplashView: View {
    /// Called when the splash should be dismissed — either the hold timer
    /// elapsed or the user tapped to skip. Idempotent at the call site.
    var onFinish: () -> Void

    @State private var appeared = false
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orchestratorColor, Color.orchestratorColor.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                logo
                Text("Pupa")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(appeared ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("Pupa")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            withAnimation(reduceMotion ? .easeIn(duration: 0.35)
                                       : .spring(response: 0.5, dampingFraction: 0.7)) {
                appeared = true
            }
        }
        .task {
            // Hold a beat after the entrance, then auto-dismiss. Cancelled
            // automatically if the user taps to skip (view disappears).
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { finish() }
        }
    }

    private var logo: some View {
        Group {
            if let icon = AppIcon.swiftUIImage {
                icon
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 116, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.6))
        .opacity(appeared ? 1 : 0)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}
