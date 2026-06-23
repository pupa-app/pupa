import Foundation
import Testing
@testable import PupaApp

/// Unit tests for the Phase 3b pairing pieces — `BackendCredentialStore`,
/// `BackendPairingClient`, and the new `SettingsStore.markPaired` /
/// `clearPairing` / `authHeaders` behaviour.
///
/// The pairing client is exercised against a `URLSessionConfiguration` with
/// a tiny in-process `URLProtocol` stub so we don't need a live backend.
@MainActor
@Suite("Backend pairing", .serialized)
struct BackendPairingTests {

    init() { TestStorage.activate() }

    // MARK: - InMemoryCredentialStore

    @Test("InMemory credential store round-trips per-backend tokens")
    func inMemory_perBackend_roundtrip() throws {
        let store = InMemoryCredentialStore()
        let a = UUID(); let b = UUID()
        try store.setToken("alpha", for: a)
        try store.setToken("beta", for: b)
        #expect(store.token(for: a) == "alpha")
        #expect(store.token(for: b) == "beta")
        try store.removeToken(for: a)
        #expect(store.token(for: a) == nil)
        #expect(store.token(for: b) == "beta")
    }

    // MARK: - SettingsStore + credential store

    @Test("authHeaders sources the bearer from the Keychain device token")
    func authHeaders_pullsFromKeychain() throws {
        SettingsStore.clearStorage()
        let credentials = InMemoryCredentialStore()
        let store = SettingsStore(credentials: credentials)
        // Fresh store: no token paired yet.
        #expect(store.authHeaders.isEmpty)

        try credentials.setToken("device-token", for: store.activeBackendID)
        #expect(store.authHeaders == ["Authorization": "Bearer device-token"])
    }

    @Test("markPaired saves the token to the credential store + records deviceID")
    func markPaired_writesBothSides() throws {
        SettingsStore.clearStorage()
        let credentials = InMemoryCredentialStore()
        let store = SettingsStore(credentials: credentials)
        let device = UUID()
        try store.markPaired(backendID: store.activeBackendID, deviceID: device, token: "tok-1")
        #expect(credentials.token(for: store.activeBackendID) == "tok-1")
        #expect(store.activeBackend.deviceID == device)
        #expect(store.isPaired(store.activeBackendID))
    }

    @Test("clearPairing removes the token + the deviceID")
    func clearPairing_removesBothSides() throws {
        SettingsStore.clearStorage()
        let credentials = InMemoryCredentialStore()
        let store = SettingsStore(credentials: credentials)
        try store.markPaired(backendID: store.activeBackendID, deviceID: UUID(), token: "tok")
        try store.clearPairing(backendID: store.activeBackendID)
        #expect(credentials.token(for: store.activeBackendID) == nil)
        #expect(store.activeBackend.deviceID == nil)
        #expect(!store.isPaired(store.activeBackendID))
    }

    @Test("deviceID persists across SettingsStore reloads")
    func deviceID_persists() throws {
        SettingsStore.clearStorage()
        let credentials = InMemoryCredentialStore()
        let writer = SettingsStore(credentials: credentials)
        let device = UUID()
        try writer.markPaired(backendID: writer.activeBackendID, deviceID: device, token: "tok")

        let reader = SettingsStore(credentials: credentials)
        #expect(reader.activeBackend.deviceID == device)
    }

    // MARK: - BackendPairingClient

    @Test("BackendPairingClient parses a successful /auth/pair response")
    func pairingClient_parsesSuccess() async throws {
        let json = """
        {"deviceId":"11111111-2222-3333-4444-555555555555","token":"tok-xyz","label":"iPhone","scopes":["agent","screenshare"]}
        """
        let stub = MockURLProtocol.respond(status: 200, body: json)
        let client = BackendPairingClient(backendURL: URL(string: "http://example.test/")!, session: stub)
        let result = try await client.pair(code: "ABCDEFGH", label: "iPhone")
        #expect(result.deviceID == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(result.token == "tok-xyz")
        #expect(result.label == "iPhone")
        #expect(result.scopes == ["agent", "screenshare"])
    }

    @Test("BackendPairingClient maps 404 to invalidCode error")
    func pairingClient_404IsInvalidCode() async throws {
        let stub = MockURLProtocol.respond(status: 404, body: "{}")
        let client = BackendPairingClient(backendURL: URL(string: "http://example.test/")!, session: stub)
        do {
            _ = try await client.pair(code: "BADCODE1", label: "x")
            Issue.record("Expected pair to throw")
        } catch PairingError.invalidCode {
            // expected
        } catch {
            Issue.record("Expected .invalidCode, got \(error)")
        }
    }

    @Test("BackendPairingClient maps 5xx to unexpectedResponse")
    func pairingClient_5xxIsUnexpected() async throws {
        let stub = MockURLProtocol.respond(status: 500, body: "boom")
        let client = BackendPairingClient(backendURL: URL(string: "http://example.test/")!, session: stub)
        do {
            _ = try await client.pair(code: "ABCDEFGH", label: "x")
            Issue.record("Expected pair to throw")
        } catch PairingError.unexpectedResponse(let status, _) {
            #expect(status == 500)
        } catch {
            Issue.record("Expected .unexpectedResponse, got \(error)")
        }
    }

    @Test("BackendPairingClient posts code + label to /auth/pair")
    func pairingClient_postsExpectedShape() async throws {
        let json = """
        {"deviceId":"11111111-2222-3333-4444-555555555555","token":"t","label":"x","scopes":[]}
        """
        let stub = MockURLProtocol.respond(status: 200, body: json) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString.hasSuffix("/auth/pair") == true)
            guard let bodyData = request.httpBodyStreamData() ?? request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            else {
                Issue.record("Couldn't decode request body")
                return
            }
            #expect(body["code"] as? String == "ABCDEFGH")
            #expect(body["label"] as? String == "iPhone")
        }
        let client = BackendPairingClient(backendURL: URL(string: "http://example.test/")!, session: stub)
        _ = try await client.pair(code: "  abcdefgh  ", label: "iPhone")
    }

    // MARK: - QR scanner code extraction

    @Test("Bare 8-char code is accepted by extractPairingCode")
    func qrScanner_bareCode() {
        #if os(iOS)
        #expect(QRScannerView.extractPairingCode(from: "ABCDEFGH") == "ABCDEFGH")
        #expect(QRScannerView.extractPairingCode(from: "  abcdefgh  ") == "ABCDEFGH")
        // Wrong length
        #expect(QRScannerView.extractPairingCode(from: "ABC") == nil)
        // Contains banned chars (1 / l / O / 0)
        #expect(QRScannerView.extractPairingCode(from: "ABCD0EFG") == nil)
        #endif
    }

    @Test("URL-style QR payload is accepted by extractPairingCode")
    func qrScanner_urlPayload() {
        #if os(iOS)
        let scanned = "pupa-pair://localhost:8004/?code=K7H3M2P4"
        #expect(QRScannerView.extractPairingCode(from: scanned) == "K7H3M2P4")
        #endif
    }

    @Test("Full pairing QR with url + fp is parsed by extractPairingResult")
    func qrScanner_fullPairingURL() {
        #if os(iOS)
        let fp = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
        let scanned = "pupa-pair://?url=https%3A%2F%2F192.168.1.100%3A8004&fp=\(fp)&code=ABCDEFGH"
        let result = QRScannerView.extractPairingResult(from: scanned)
        #expect(result?.code == "ABCDEFGH")
        #expect(result?.backendURL?.absoluteString == "https://192.168.1.100:8004")
        #expect(result?.certFingerprint == fp)
        #endif
    }

    @Test("QR without url/fp still returns code only")
    func qrScanner_codeOnly() {
        #if os(iOS)
        let result = QRScannerView.extractPairingResult(from: "pupa-pair://?code=ABCDEFGH")
        #expect(result?.code == "ABCDEFGH")
        #expect(result?.backendURL == nil)
        #expect(result?.certFingerprint == nil)
        #endif
    }
}


// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Build a URLSession whose only configured `URLProtocol` is the mock,
    /// and pre-register a handler that returns the given status/body.
    static func respond(
        status: Int,
        body: String,
        inspect: (@Sendable (URLRequest) -> Void)? = nil
    ) -> URLSession {
        let data = body.data(using: .utf8) ?? Data()
        handler = { req in
            inspect?(req)
            let response = HTTPURLResponse(
                url: req.url ?? URL(string: "http://example.test/")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol receives streamed bodies; read the stream into Data so
    /// tests can JSON-decode it.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data.isEmpty ? nil : data
    }
}
