import MarkdownUI
import SwiftUI

/// Markdown image provider that fetches only when the surrounding app allows it.
///
/// MarkdownUI's `DefaultImageProvider` is network-backed and loads **on
/// render**, so a markdown image in attacker-authored content — an imported
/// memory file, a bundle's notes — is a zero-click callout to a host of its
/// choosing. Because ATS permits local networking, it can also probe the LAN.
/// Inside an app whose content arrived in a bundle that has to be the user's
/// decision, so `MyApp.allowsRemoteImages` gates it.
///
/// One type with a flag rather than two providers, because `markdownImageProvider`
/// takes a concrete type — a ternary between two provider types doesn't compile.
///
/// The withheld branch says why the image is missing rather than rendering
/// nothing, so a blank space isn't mistaken for a broken file.
struct GatedImageProvider: ImageProvider {
    let allowed: Bool

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if allowed {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            Label("Image not loaded", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .help(url?.host.map { "Didn't contact \($0) — remote images are off for this app" }
                      ?? "Remote images are off for this app")
        }
    }
}

extension ImageProvider where Self == GatedImageProvider {
    static func gated(allowed: Bool) -> Self { .init(allowed: allowed) }
}
