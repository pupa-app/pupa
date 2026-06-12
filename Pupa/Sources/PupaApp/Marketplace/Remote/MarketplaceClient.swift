import CryptoKit
import Foundation

/// Fetches the catalog + bundle bytes from a `MarketplaceSource`. Pure
/// transport: it verifies transport-level integrity (scheme, size caps,
/// SHA-256) but performs **no** store/disk mutation and does not trust the
/// bytes — install still runs the full `MyAppImporter` gate.
public protocol MarketplaceFetching: Sendable {
    func fetchCatalog(_ source: MarketplaceSource) async throws -> MarketplaceCatalog
    func download(_ entry: MarketplaceCatalog.Entry, from source: MarketplaceSource) async throws -> Data
}

public enum MarketplaceError: LocalizedError, Equatable {
    case insecureSource
    case badStatus(Int)
    case sizeExceeded
    case checksumMismatch
    case malformedCatalog
    case newerCatalog(found: Int, supported: Int)
    case invalidPath
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .insecureSource:
            return "Marketplace sources must use HTTPS."
        case .badStatus(let code):
            return "The marketplace returned an error (HTTP \(code))."
        case .sizeExceeded:
            return "An item is too large to download safely."
        case .checksumMismatch:
            return "A downloaded item failed its integrity check and was rejected."
        case .malformedCatalog:
            return "The marketplace catalog is malformed."
        case .newerCatalog(let found, let supported):
            return "This marketplace needs a newer version of Pupa "
                + "(catalog format \(found) > \(supported))."
        case .invalidPath:
            return "The marketplace catalog referenced an invalid path."
        case .network(let why):
            return "Couldn't reach the marketplace: \(why)"
        }
    }
}

public struct MarketplaceClient: MarketplaceFetching {
    /// Catalog cap is separate from (and smaller than) the bundle cap.
    static let maxCatalogBytes = 4 * 1024 * 1024

    private let timeout: TimeInterval
    /// Builds the session for a source — pins by cert fingerprint when set,
    /// else system trust. Injectable so tests can supply a `URLProtocol` stub.
    private let sessionProvider: @Sendable (MarketplaceSource) -> URLSession

    /// Production: pin by the source's cert fingerprint when set, else system
    /// trust. (`forBackend` is internal, so it can't be a default arg value.)
    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
        self.sessionProvider = { URLSession.forBackend(certFingerprint: $0.certFingerprint) }
    }

    public init(timeout: TimeInterval = 20,
                sessionProvider: @escaping @Sendable (MarketplaceSource) -> URLSession) {
        self.timeout = timeout
        self.sessionProvider = sessionProvider
    }

    /// Test convenience: route every request through one fixed session.
    public init(timeout: TimeInterval = 20, session: URLSession) {
        self.timeout = timeout
        self.sessionProvider = { _ in session }
    }

    public func fetchCatalog(_ source: MarketplaceSource) async throws -> MarketplaceCatalog {
        guard source.hasAllowedScheme else { throw MarketplaceError.insecureSource }
        let data = try await get(source.indexURL, source: source, cap: Self.maxCatalogBytes)
        if let pin = source.pinnedIndexSHA256, Self.sha256Hex(data) != pin.lowercased() {
            throw MarketplaceError.checksumMismatch
        }
        let catalog: MarketplaceCatalog
        do {
            catalog = try MarketplaceCatalog.makeDecoder().decode(MarketplaceCatalog.self, from: data)
        } catch {
            throw MarketplaceError.malformedCatalog
        }
        guard catalog.formatVersion <= MarketplaceCatalog.currentFormatVersion else {
            throw MarketplaceError.newerCatalog(found: catalog.formatVersion,
                                                supported: MarketplaceCatalog.currentFormatVersion)
        }
        return catalog
    }

    public func download(_ entry: MarketplaceCatalog.Entry,
                         from source: MarketplaceSource) async throws -> Data {
        guard source.hasAllowedScheme else { throw MarketplaceError.insecureSource }
        guard Self.isSafePath(entry.path) else { throw MarketplaceError.invalidPath }
        // Pre-filter on the advertised size before spending bandwidth.
        guard entry.sizeBytes <= MyAppImporter.maxBundleBytes else { throw MarketplaceError.sizeExceeded }
        let data = try await get(source.bundleURL(path: entry.path),
                                 source: source, cap: MyAppImporter.maxBundleBytes)
        guard Self.sha256Hex(data) == entry.sha256.lowercased() else {
            throw MarketplaceError.checksumMismatch
        }
        return data
    }

    // MARK: - Transport

    private func get(_ url: URL, source: MarketplaceSource, cap: Int) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpMethod = "GET"
        let data: Data, response: URLResponse
        do {
            (data, response) = try await sessionProvider(source).data(for: req)
        } catch let urlError as URLError {
            throw MarketplaceError.network(urlError.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarketplaceError.badStatus(http.statusCode)
        }
        guard data.count <= cap else { throw MarketplaceError.sizeExceeded }
        return data
    }

    // MARK: - Helpers

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reject absolute URLs, schemes, and `..` traversal in a catalog path so a
    /// hostile manifest can't redirect the fetch off-host or up the tree.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("://"),
              !path.contains("..") else { return false }
        return true
    }
}
