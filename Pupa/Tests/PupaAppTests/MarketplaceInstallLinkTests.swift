import Foundation
import Testing
@testable import PupaApp

/// `pupa-install://` link validation — the untrusted edge of the marketplace
/// web page's iOS path. Every case here is a link a hostile page could put in
/// front of a user, so the tests are mostly about what gets *rejected*.
///
/// The download is exercised against an in-process `URLProtocol` stub — no
/// network. `AppView.stageRemoteImport` only presents what it returns.
@Suite("Marketplace install links", .serialized)
struct MarketplaceInstallLinkTests {

    /// A real catalog entry from `marketplace/index.json`.
    private static let bundle =
        "https://raw.githubusercontent.com/pupa-app/marketplace/main/apps/myfire/app.pupa"
    private static let digest =
        "8f8a67cf51bf8dba612aab1a8534d447f42003f273ed3ca5aeb5e9397e80e3e6"

    private static func link(url: String = bundle, sha: String = digest,
                             host: String = "import") -> URL {
        var c = URLComponents()
        c.scheme = MarketplaceInstallLink.scheme
        c.host = host
        c.queryItems = [.init(name: "url", value: url), .init(name: "sha256", value: sha)]
        return c.url!
    }

    // MARK: Accepted

    @Test("A well-formed marketplace link parses")
    func validLink() throws {
        let request = try MarketplaceInstallLink.parse(Self.link())
        #expect(request.bundleURL.absoluteString == Self.bundle)
        #expect(request.sha256 == Self.digest)
    }

    @Test("An uppercase digest is accepted and normalised")
    func uppercaseDigest() throws {
        let request = try MarketplaceInstallLink.parse(Self.link(sha: Self.digest.uppercased()))
        #expect(request.sha256 == Self.digest)
    }

    // MARK: Rejected — wrong link shape

    @Test("A non-install scheme is not an install link")
    func wrongScheme() {
        // The in-app chat scheme, which is deliberately unregistered — if it
        // ever did arrive from outside, it must not be treated as an install.
        #expect(throws: MarketplaceInstallLink.LinkError.notAnInstallLink) {
            try MarketplaceInstallLink.parse(URL(string: "pupa://memory/notes.md")!)
        }
    }

    @Test("An unknown action host is rejected")
    func wrongHost() {
        #expect(throws: MarketplaceInstallLink.LinkError.notAnInstallLink) {
            try MarketplaceInstallLink.parse(Self.link(host: "install"))
        }
    }

    @Test("A missing sha256 is rejected")
    func missingDigest() {
        var c = URLComponents()
        c.scheme = MarketplaceInstallLink.scheme
        c.host = "import"
        c.queryItems = [.init(name: "url", value: Self.bundle)]
        #expect(throws: MarketplaceInstallLink.LinkError.missingParameters) {
            try MarketplaceInstallLink.parse(c.url!)
        }
    }

    @Test("A malformed sha256 is rejected before any download")
    func malformedDigest() {
        #expect(throws: MarketplaceInstallLink.LinkError.missingParameters) {
            try MarketplaceInstallLink.parse(Self.link(sha: "not-a-digest"))
        }
        #expect(throws: MarketplaceInstallLink.LinkError.missingParameters) {
            try MarketplaceInstallLink.parse(Self.link(sha: String(repeating: "a", count: 63)))
        }
    }

    // MARK: Rejected — untrusted source

    @Test("A bundle URL outside the marketplace repo is rejected")
    func foreignHost() {
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(url: "https://evil.example/app.pupa")
        }
    }

    @Test("A different repo on the same host is rejected")
    func foreignRepo() {
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(url: "https://raw.githubusercontent.com/evil/repo/main/app.pupa")
        }
    }

    @Test("Plain http is rejected")
    func insecureScheme() {
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(
                url: "http://raw.githubusercontent.com/pupa-app/marketplace/main/apps/myfire/app.pupa")
        }
    }

    @Test("Userinfo can't forge the allow-listed host")
    func userinfoSpoof() {
        // `https://raw.githubusercontent.com@evil.example/…` resolves to
        // evil.example — a string-prefix allow-list would have let this pass.
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(
                url: "https://raw.githubusercontent.com@evil.example/pupa-app/marketplace/a.pupa")
        }
    }

    @Test("Path traversal out of the marketplace prefix is rejected")
    func pathTraversal() {
        // URL does not normalise `..` away, so the prefix check alone would pass.
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(
                url: "https://raw.githubusercontent.com/pupa-app/marketplace/../../evil/repo/a.pupa")
        }
    }

    @Test("A non-.pupa path is rejected")
    func wrongExtension() {
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(
                url: "https://raw.githubusercontent.com/pupa-app/marketplace/main/apps/myfire/README.md")
        }
    }

    @Test("A ref other than main is rejected")
    func foreignRef() {
        // raw.githubusercontent serves any commit in the repo's network under
        // the base repo's path — including the head of an unmerged fork PR, by
        // sha or by `refs/pull/N/head`. Anyone who can open a PR against the
        // public marketplace could otherwise host bytes at an allow-listed URL.
        for ref in ["refs/pull/1/head",
                    "0123456789abcdef0123456789abcdef01234567",
                    "some-branch"] {
            #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
                try MarketplaceInstallLink.parse(
                    url: "https://raw.githubusercontent.com/pupa-app/marketplace/\(ref)/apps/myfire/app.pupa")
            }
        }
    }

    @Test("A path outside apps/ is rejected")
    func outsideApps() {
        #expect(throws: MarketplaceInstallLink.LinkError.untrustedSource) {
            try MarketplaceInstallLink.parse(
                url: "https://raw.githubusercontent.com/pupa-app/marketplace/main/scratch/a.pupa")
        }
    }

    // MARK: Checksum

    @Test("verify accepts bytes matching the digest and rejects anything else")
    func checksum() {
        let data = Data("pupa".utf8)
        let digest = "9bef6754a810d4eb6c73e5b4ca466296a45c7fe585eecae3f4567eca3269ea3e"
        #expect(MarketplaceInstallLink.verify(data, sha256: digest))
        #expect(MarketplaceInstallLink.verify(data, sha256: digest.uppercased()))
        // Same digest, different bytes — the case a swapped payload would hit.
        #expect(!MarketplaceInstallLink.verify(Data("pupb".utf8), sha256: digest))
    }

    @Test("Digest format check accepts 64 hex digits and nothing else")
    func digestFormat() {
        #expect(MarketplaceInstallLink.isWellFormedSHA256(Self.digest))
        #expect(!MarketplaceInstallLink.isWellFormedSHA256(""))
        #expect(!MarketplaceInstallLink.isWellFormedSHA256(String(repeating: "a", count: 65)))
        #expect(!MarketplaceInstallLink.isWellFormedSHA256(String(repeating: "g", count: 64)))
    }

    // MARK: Download

    /// Bytes + the digest a link would have to carry for them.
    private static let payload = Data("pupa".utf8)
    private static let payloadDigest =
        "9bef6754a810d4eb6c73e5b4ca466296a45c7fe585eecae3f4567eca3269ea3e"

    private static func request(sha: String = payloadDigest) -> MarketplaceInstallLink.Request {
        .init(bundleURL: URL(string: bundle)!, sha256: sha)
    }

    /// A session whose only loader is the in-process stub.
    private static func stub(status: Int, body: Data,
                             headers: [String: String] = [:]) -> URLSession {
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(
                url: req.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (response, body)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("Bytes matching the link's digest are returned")
    func fetchHappyPath() async throws {
        let data = try await MarketplaceInstallLink.fetchBundle(
            Self.request(), using: Self.stub(status: 200, body: Self.payload))
        #expect(data == Self.payload)
    }

    @Test("A non-200 response is a download failure")
    func fetchNotFound() async {
        await #expect(throws: MarketplaceInstallLink.LinkError.unavailable) {
            try await MarketplaceInstallLink.fetchBundle(
                Self.request(), using: Self.stub(status: 404, body: Data()))
        }
    }

    @Test("Swapped bytes are rejected even from the allow-listed host")
    func fetchChecksumMismatch() async {
        await #expect(throws: MarketplaceInstallLink.LinkError.checksumMismatch) {
            try await MarketplaceInstallLink.fetchBundle(
                Self.request(), using: Self.stub(status: 200, body: Data("pupb".utf8)))
        }
    }

    @Test("A declared Content-Length over the cap is rejected before the body is read")
    func fetchTooLargeByHeader() async {
        let session = Self.stub(status: 200, body: Self.payload,
                                headers: ["Content-Length": "\(MyAppImporter.maxBundleBytes + 1)"])
        await #expect(throws: MarketplaceInstallLink.LinkError.tooLarge) {
            try await MarketplaceInstallLink.fetchBundle(Self.request(), using: session)
        }
    }

    @Test("A response that doesn't declare its size is capped while reading")
    func fetchTooLargeWhileStreaming() async {
        // No Content-Length, so the header check can't fire — the running cap
        // has to stop it.
        await #expect(throws: MarketplaceInstallLink.LinkError.tooLarge) {
            try await MarketplaceInstallLink.fetchBundle(
                Self.request(), using: Self.stub(status: 200, body: Self.payload), maxBytes: 2)
        }
    }
}

// MARK: - Helpers

private extension MarketplaceInstallLink {
    /// Parse a link built around `url`, keeping the source-allow-list tests to
    /// the one thing they vary.
    static func parse(url: String) throws -> Request {
        var c = URLComponents()
        c.scheme = scheme
        c.host = installHost
        c.queryItems = [
            .init(name: "url", value: url),
            .init(name: "sha256", value: String(repeating: "a", count: 64)),
        ]
        return try parse(c.url!)
    }
}
