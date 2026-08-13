import CryptoKit
import Foundation

/// Parses and fulfils `pupa-install://import?url=…&sha256=…` — the marketplace
/// page's iOS path, where Safari can't hand a `.pupa` to Pupa directly.
///
/// **The link is untrusted** (any web page can emit one). Two guards: the
/// bundle URL is allow-listed to the marketplace catalog *by component*, and
/// the bytes are checksummed. Neither makes the payload safe — a link can still
/// name a real app the user didn't ask for — so `ImportConfirmSheet` stays the
/// gate, as for a tapped file. See `docs/marketplace.md`.
enum MarketplaceInstallLink {

    /// Registered in the PupaHost Info.plist. The in-app `pupa` (ChatLink) and
    /// `pupa-pair` (QR) schemes stay unregistered — no web page should reach
    /// the paths that consume them.
    static let scheme = "pupa-install"
    /// The only action understood, so a future one can't be mistaken for it.
    static let installHost = "import"

    /// The catalog page the Import screen sends users to. Tapping an app there
    /// comes back as an install link; nothing in the app reads the catalog.
    static let browseURL = URL(string: "https://pupa-app.com/marketplace")!

    static let allowedHost = "raw.githubusercontent.com"
    /// Pinned to `main/apps/`, not the repo root: raw.githubusercontent serves
    /// **any** commit in a repo's network under the base repo's path, including
    /// unmerged fork-PR heads (`…/marketplace/<pr-head-sha>/…` and
    /// `…/marketplace/refs/pull/N/head/…` both return 200). A repo-wide prefix
    /// would let anyone who can open a PR host arbitrary bytes at an
    /// allow-listed URL. `main` is what the marketplace page links to anyway.
    static let allowedPathPrefix = "/pupa-app/marketplace/main/apps/"

    /// `bundleURL` is known to point into the marketplace catalog; `sha256` is
    /// known to be well-formed, not yet matched against any bytes.
    struct Request: Equatable {
        let bundleURL: URL
        let sha256: String
    }

    enum LinkError: LocalizedError, Equatable {
        case notAnInstallLink
        case missingParameters
        case untrustedSource
        case unavailable
        case tooLarge
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .notAnInstallLink, .missingParameters:
                return "That marketplace link is incomplete, so nothing was imported."
            case .untrustedSource:
                return "That link points outside the Pupa marketplace, so it wasn't opened."
            case .unavailable:
                return "Couldn't download that app from the marketplace."
            case .tooLarge:
                return "That app is too large to import."
            case .checksumMismatch:
                return "That download didn't match the checksum in the link, so it wasn't imported."
            }
        }
    }

    /// Validate a tapped link. Pure — no network, no state.
    static func parse(_ url: URL) throws -> Request {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == installHost else {
            throw LinkError.notAnInstallLink
        }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value,
              let sha = items.first(where: { $0.name == "sha256" })?.value,
              let bundleURL = URL(string: raw),
              isWellFormedSHA256(sha) else {
            throw LinkError.missingParameters
        }
        guard isMarketplaceURL(bundleURL) else { throw LinkError.untrustedSource }
        return Request(bundleURL: bundleURL, sha256: sha.lowercased())
    }

    /// Component-wise, not a string prefix: `https://raw.githubusercontent.com@evil/…`
    /// passes a prefix check but parses to `host == evil`, and `..` must be
    /// rejected explicitly because `URL` doesn't normalise it away.
    static func isMarketplaceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedHost,
              url.path.hasPrefix(allowedPathPrefix),
              !url.pathComponents.contains(".."),
              url.pathExtension.lowercased() == "pupa" else {
            return false
        }
        return true
    }

    /// 64 hex digits, either case — what `index.json` publishes.
    static func isWellFormedSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// Plain comparison: an integrity check on public data, not a secret.
    static func verify(_ data: Data, sha256 expected: String) -> Bool {
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return actual == expected.lowercased()
    }

    /// Download the bundle a validated link names and return it only if the
    /// bytes match the link's digest. Never writes to disk or to the store —
    /// the caller stages the result behind the same confirm sheet a tapped
    /// file gets.
    ///
    /// Streamed, not buffered whole: the response is capped at
    /// `MyAppImporter.maxBundleBytes` from the declared `Content-Length` where
    /// there is one, and again while reading for a response that doesn't
    /// declare its size.
    static func fetchBundle(
        _ request: Request,
        using session: URLSession = .shared,
        maxBytes cap: Int = MyAppImporter.maxBundleBytes
    ) async throws -> Data {
        var req = URLRequest(url: request.bundleURL)
        req.timeoutInterval = 30

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(for: req)
        } catch {
            throw LinkError.unavailable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LinkError.unavailable
        }
        let declared = http.expectedContentLength
        guard declared <= Int64(cap) else { throw LinkError.tooLarge }

        var data = Data()
        if declared > 0 { data.reserveCapacity(Int(declared)) }
        do {
            for try await byte in stream {
                data.append(byte)
                guard data.count <= cap else { throw LinkError.tooLarge }
            }
        } catch let error as LinkError {
            throw error
        } catch {
            throw LinkError.unavailable
        }

        guard verify(data, sha256: request.sha256) else { throw LinkError.checksumMismatch }
        return data
    }
}
