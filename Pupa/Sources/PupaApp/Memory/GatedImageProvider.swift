import MarkdownUI
import SwiftUI

/// Markdown image provider that fetches only when the app allows it.
///
/// MarkdownUI's `DefaultImageProvider` loads on render, so an image URL in
/// attacker-authored content is a callout with no interaction. Imported apps
/// start with `MyApp.allowsRemoteImages` off; see `docs/marketplace.md`.
///
/// One type with a flag rather than two providers, because
/// `markdownImageProvider` takes a concrete type.
struct GatedImageProvider: ImageProvider {
    let allowed: Bool

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if allowed {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            WithheldImage(host: url?.host)
        }
    }
}

extension ImageProvider where Self == GatedImageProvider {
    static func gated(allowed: Bool) -> Self { .init(allowed: allowed) }
}

/// Placeholder for an image that wasn't fetched — and the switch to fetch it.
///
/// The control lives here rather than in a settings screen because this is
/// where the user notices: they see a missing picture and can turn loading on
/// for this app in place. Says which host it would contact, so the choice is
/// informed.
struct WithheldImage: View {
    let host: String?
    @Environment(\.enableRemoteImages) private var enableRemoteImages

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            if let enableRemoteImages {
                Button("Load images", action: enableRemoteImages)
                    .buttonStyle(.plain)
                    .underline()
            } else {
                Text("Image not loaded")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .help(host.map { "Hasn't contacted \($0). Imported apps don't load remote images until you allow it." }
              ?? "Imported apps don't load remote images until you allow it.")
        .accessibilityLabel(host.map { "Image from \($0) not loaded" } ?? "Image not loaded")
    }
}
