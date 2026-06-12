import Foundation
import Observation

/// UI-facing state for the marketplace browser: the fetched catalog, load
/// state, and an offline cache. Delegates transport to a `MarketplaceFetching`
/// (injectable for tests). Install routes the downloaded bytes straight into
/// `MyAppImporter.importBundle` — the network never bypasses that gate.
@MainActor
@Observable
public final class MarketplaceStore {
    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: LoadState = .idle
    public private(set) var catalog: MarketplaceCatalog?
    /// True when `catalog` came from the offline cache after a failed refresh.
    public private(set) var isStale = false
    public private(set) var lastUpdated: Date?

    @ObservationIgnored private let client: MarketplaceFetching
    @ObservationIgnored private let cacheURL: URL?

    public init(client: MarketplaceFetching = MarketplaceClient(), cacheDirectory: URL? = nil) {
        self.client = client
        let dir = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.cacheURL = dir?.appendingPathComponent("pupa-marketplace-catalog.json")
    }

    /// Fetch the catalog. On failure, fall back to the cached copy (flagged
    /// stale) so the browser still shows something offline.
    public func refresh(source: MarketplaceSource) async {
        state = .loading
        do {
            let fresh = try await client.fetchCatalog(source)
            catalog = fresh
            isStale = false
            lastUpdated = Date()
            state = .loaded
            saveCache(fresh)
        } catch {
            if let cached = loadCache() {
                catalog = cached.catalog
                isStale = true
                lastUpdated = cached.savedAt
                state = .loaded
            } else {
                state = .failed((error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription)
            }
        }
    }

    /// Download + integrity-verify a bundle's bytes (no import yet).
    public func download(_ entry: MarketplaceCatalog.Entry,
                        from source: MarketplaceSource) async throws -> Data {
        try await client.download(entry, from: source)
    }

    // MARK: - Offline cache

    private struct Cached: Codable { let savedAt: Date; let catalog: MarketplaceCatalog }

    private func saveCache(_ catalog: MarketplaceCatalog) {
        guard let cacheURL else { return }
        let payload = Cached(savedAt: Date(), catalog: catalog)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadCache() -> Cached? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cached.self, from: data)
    }
}
