import Foundation
import Testing
@testable import PupaApp

/// Remote marketplace: catalog fetch, integrity gates, and the offline cache.
/// All network is stubbed via `URLProtocol` — no live traffic. Serialized
/// because the stub's response handler is process-global static state.
@Suite("Marketplace remote", .serialized)
struct MarketplaceRemoteTests {

    // MARK: Fixtures

    private let source = MarketplaceSource(
        label: "Test", baseURL: URL(string: "https://example.test/catalog/")!)

    private func entry(sha256: String, sizeBytes: Int = 100,
                       path: String = "apps/x.pupaapp") -> MarketplaceCatalog.Entry {
        MarketplaceCatalog.Entry(
            id: "x", name: "X", appFormatVersion: 1,
            path: path, sizeBytes: sizeBytes, sha256: sha256)
    }

    private func catalogJSON(formatVersion: Int = 1) -> Data {
        try! JSONEncoder().encode(MarketplaceCatalog(
            formatVersion: formatVersion,
            entries: [entry(sha256: "deadbeef")]))
    }

    /// A session that answers every request through `handler`.
    private func session(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> URLSession {
        StubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func client(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> MarketplaceClient {
        MarketplaceClient(session: session(handler))
    }

    // MARK: Catalog

    @Test("Valid catalog decodes")
    func catalogDecodes() async throws {
        let c = client { _ in (200, self.catalogJSON()) }
        let catalog = try await c.fetchCatalog(source)
        #expect(catalog.entries.count == 1)
        #expect(catalog.entries.first?.name == "X")
    }

    @Test("Newer catalog format is hard-rejected")
    func newerCatalogRejected() async throws {
        let c = client { _ in (200, self.catalogJSON(formatVersion: 99)) }
        await #expect(throws: MarketplaceError.newerCatalog(found: 99, supported: 1)) {
            _ = try await c.fetchCatalog(source)
        }
    }

    @Test("Malformed catalog throws")
    func malformedCatalog() async throws {
        let c = client { _ in (200, Data("not json".utf8)) }
        await #expect(throws: MarketplaceError.malformedCatalog) {
            _ = try await c.fetchCatalog(source)
        }
    }

    @Test("HTTP error surfaces as badStatus")
    func badStatus() async throws {
        let c = client { _ in (404, Data()) }
        await #expect(throws: MarketplaceError.badStatus(404)) {
            _ = try await c.fetchCatalog(source)
        }
    }

    // MARK: Download integrity

    @Test("Checksum mismatch is rejected")
    func checksumMismatch() async throws {
        let bytes = Data("hello".utf8)
        let c = client { _ in (200, bytes) }
        await #expect(throws: MarketplaceError.checksumMismatch) {
            _ = try await c.download(self.entry(sha256: "00bad00"), from: source)
        }
    }

    @Test("Matching checksum returns bytes")
    func checksumMatch() async throws {
        let bytes = Data("hello".utf8)
        let hex = MarketplaceClient.sha256Hex(bytes)
        let c = client { _ in (200, bytes) }
        let out = try await c.download(entry(sha256: hex, sizeBytes: bytes.count), from: source)
        #expect(out == bytes)
    }

    @Test("Oversize entry is rejected before download")
    func oversizeRejected() async throws {
        let c = client { _ in (200, Data()) }  // never reached
        let big = entry(sha256: "x", sizeBytes: MyAppImporter.maxBundleBytes + 1)
        await #expect(throws: MarketplaceError.sizeExceeded) {
            _ = try await c.download(big, from: source)
        }
    }

    // MARK: Pure guards

    @Test("Hostile catalog paths are rejected")
    func unsafePaths() {
        #expect(!MarketplaceClient.isSafePath("../secrets"))
        #expect(!MarketplaceClient.isSafePath("/etc/passwd"))
        #expect(!MarketplaceClient.isSafePath("https://evil.example/x"))
        #expect(!MarketplaceClient.isSafePath(""))
        #expect(MarketplaceClient.isSafePath("apps/habit.pupaapp"))
    }

    @Test("Only HTTPS (or loopback http) sources are allowed")
    func schemePolicy() {
        func s(_ u: String) -> Bool {
            MarketplaceSource(label: "", baseURL: URL(string: u)!).hasAllowedScheme
        }
        #expect(s("https://example.com/"))
        #expect(s("http://localhost:8080/"))
        #expect(s("http://127.0.0.1/"))
        #expect(!s("http://example.com/"))
    }

    @Test("Non-HTTPS source fails the fetch")
    func insecureSourceRejected() async throws {
        let insecure = MarketplaceSource(label: "", baseURL: URL(string: "http://evil.example/")!)
        let c = client { _ in (200, self.catalogJSON()) }
        await #expect(throws: MarketplaceError.insecureSource) {
            _ = try await c.fetchCatalog(insecure)
        }
    }

    // MARK: Store + offline cache

    @MainActor
    @Test("Refresh failure falls back to cached catalog")
    func offlineFallsBackToCache() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-mkt-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // First store succeeds and writes the cache.
        let good = MarketplaceStore(
            client: StubFetcher(catalog: .success(MarketplaceCatalog(entries: [entry(sha256: "a")]))),
            cacheDirectory: cacheDir)
        await good.refresh(source: source)
        #expect(good.state == .loaded)
        #expect(good.isStale == false)

        // Second store fails but reads the cache written above.
        let offline = MarketplaceStore(
            client: StubFetcher(catalog: .failure(MarketplaceError.network("down"))),
            cacheDirectory: cacheDir)
        await offline.refresh(source: source)
        #expect(offline.state == .loaded)
        #expect(offline.isStale == true)
        #expect(offline.catalog?.entries.count == 1)
    }

    @MainActor
    @Test("Refresh failure with no cache surfaces an error")
    func offlineNoCacheFails() async {
        let store = MarketplaceStore(
            client: StubFetcher(catalog: .failure(MarketplaceError.network("down"))),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pupa-mkt-empty-\(UUID().uuidString)", isDirectory: true))
        await store.refresh(source: source)
        if case .failed = store.state {} else { Issue.record("expected .failed, got \(store.state)") }
    }
}

// MARK: - Stubs

/// In-process `MarketplaceFetching` for store-level tests.
private struct StubFetcher: MarketplaceFetching {
    var catalog: Result<MarketplaceCatalog, Error>
    var bundle: Result<Data, Error> = .success(Data())
    func fetchCatalog(_ source: MarketplaceSource) async throws -> MarketplaceCatalog {
        try catalog.get()
    }
    func download(_ entry: MarketplaceCatalog.Entry, from source: MarketplaceSource) async throws -> Data {
        try bundle.get()
    }
}

/// Canned-response `URLProtocol` so `MarketplaceClient` tests never hit the net.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
