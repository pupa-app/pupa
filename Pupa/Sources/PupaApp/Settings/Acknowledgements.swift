import Foundation

/// One third-party package linked into Pupa's binaries, with the attribution
/// MIT and BSD require to ship *with the binary* — `NOTICE.md` alone only
/// covers someone reading the source.
///
/// Every field except `licenceText` mirrors a cell of `NOTICE.md`'s table;
/// `AcknowledgementsTests` parses that table and fails if the two drift.
struct Acknowledgement: Identifiable, Sendable, Equatable {
    /// Package name, as `NOTICE.md` links it.
    let name: String
    /// Project home.
    let url: URL
    /// SPDX identifier.
    let licence: String
    /// Copyright holder.
    let copyright: String
    /// How it reaches the binary — direct dependency or transitive.
    let origin: String
    /// The package's own licence file, verbatim.
    let licenceText: String

    var id: String { name }
}

extension Acknowledgement {
    /// Every third-party package in the shipped app, in `NOTICE.md`'s order.
    /// `AGUIKit` has no external dependencies, so nothing here comes from it.
    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "swift-markdown-ui",
            url: URL(string: "https://github.com/gonzalezreal/swift-markdown-ui")!,
            licence: "MIT",
            copyright: "2020 Guillermo Gonzalez",
            origin: "Direct — renders chat markdown",
            licenceText: LicenceText.swiftMarkdownUI
        ),
        Acknowledgement(
            name: "NetworkImage",
            url: URL(string: "https://github.com/gonzalezreal/NetworkImage")!,
            licence: "MIT",
            copyright: "2020 Guille Gonzalez",
            origin: "Transitive, via swift-markdown-ui",
            licenceText: LicenceText.networkImage
        ),
        Acknowledgement(
            name: "swift-cmark",
            url: URL(string: "https://github.com/swiftlang/swift-cmark")!,
            licence: "BSD-2-Clause",
            copyright: "2014 John MacFarlane",
            origin: "Transitive, via swift-markdown-ui",
            licenceText: LicenceText.swiftCmark
        ),
        Acknowledgement(
            name: "WebRTC",
            url: URL(string: "https://github.com/stasel/WebRTC")!,
            licence: "BSD-3-Clause",
            copyright: "The WebRTC project authors",
            origin: "Direct — voice session transport",
            licenceText: LicenceText.webRTC
        ),
    ]
}
