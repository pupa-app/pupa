import Foundation

/// A remote marketplace = any HTTPS host serving an `index.json` catalog plus
/// the `.pupaapp` bundles it lists. Host-agnostic on purpose: GitHub raw today,
/// a real backend later, both are just a `baseURL`. The bundles it serves are
/// untrusted — `MyAppImporter.importBundle` stays the security boundary; this
/// type only decides *where* the bytes come from.
public struct MarketplaceSource: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    /// Catalog/bundle root. Must end in `/` so relative paths resolve under it.
    /// Pin to an immutable ref by baking a commit SHA into the path.
    public var baseURL: URL
    /// Optional SHA-256 (hex) of `index.json`; when set the client rejects a
    /// catalog whose bytes don't match (defends against a swapped manifest).
    public var pinnedIndexSHA256: String?
    /// Optional self-hosted TLS pin (SHA-256 of the leaf cert). `nil` ⇒ system
    /// trust, which is what public hosts like GitHub use.
    public var certFingerprint: String?

    public init(
        id: UUID = UUID(),
        label: String,
        baseURL: URL,
        pinnedIndexSHA256: String? = nil,
        certFingerprint: String? = nil
    ) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
        self.pinnedIndexSHA256 = pinnedIndexSHA256
        self.certFingerprint = certFingerprint
    }

    /// The baked-in official source. The repo it points at is the catalog of
    /// record; users can repoint to their own by editing the source URL.
    public static let officialDefault = MarketplaceSource(
        label: "Pupa Marketplace",
        baseURL: URL(string: "https://raw.githubusercontent.com/pupa-app/marketplace/main/")!)

    /// HTTPS only, except plain `http` for loopback (local-dev catalogs). A
    /// hostile catalog can't be served over a downgraded transport.
    public var hasAllowedScheme: Bool {
        switch baseURL.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(baseURL.host ?? "")
        default: return false
        }
    }

    public var indexURL: URL { baseURL.appendingPathComponent("index.json") }

    /// Resolve a catalog-relative bundle path under `baseURL`. The path itself
    /// is attacker-controlled; `MarketplaceClient` validates it before use.
    public func bundleURL(path: String) -> URL { baseURL.appendingPathComponent(path) }
}
