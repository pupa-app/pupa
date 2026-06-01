import Foundation

/// Probe response from `GET /auth/config`. Powers the per-backend status
/// badge in the Settings list ([#73](https://github.com/*/issues/73)).
public struct BackendConfig: Codable, Equatable, Sendable {
    public let authRequired: Bool
    public let methods: [String]
    public let version: String?

    /// Convenience — true when the backend accepts the shared-secret
    /// API key mechanism (today's only method; `"pairing"` and `"apple"`
    /// arrive with [#163](https://github.com/*/issues/163)).
    public var acceptsAPIKey: Bool { methods.contains("api_key") }
}

public struct BackendConfigClient: Sendable {
    public let endpoint: URL
    public let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        backendURL: URL,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.endpoint = backendURL.appendingPathComponent("auth/config")
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func fetch() async throws -> BackendConfig {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // `/auth/config` is always-public (see backend `_is_public`), so the
        // Authorization header is technically unnecessary. We still attach it
        // for the case where a hostile middleware in front of FastAPI demands
        // one regardless — costs nothing.
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        // Shorter than the global default; the probe is best-effort UI fluff,
        // we don't want a stuck backend to stall the Settings sheet.
        req.timeoutInterval = 6
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(BackendConfig.self, from: data)
    }
}
