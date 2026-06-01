import Foundation

/// One backend tool as advertised by `GET /backend-tools` on the FastAPI
/// backend. The iOS Settings sheet renders one toggle per entry.
public struct BackendToolDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let description: String
    /// True when the server has the gating env var set (e.g. `TAVILY_API_KEY`).
    /// When false the toggle is shown disabled — flipping it would do nothing
    /// because the backend can't materialise the tool anyway.
    public let enabledByEnv: Bool

    public var id: String { name }

    public init(name: String, description: String, enabledByEnv: Bool) {
        self.name = name
        self.description = description
        self.enabledByEnv = enabledByEnv
    }
}

/// Tiny URLSession-backed fetcher for the backend tools registry. Lives
/// independently of AGUIKit because it talks to a sibling REST route, not
/// the AG-UI streaming endpoint.
public struct BackendToolsClient: Sendable {
    public let endpoint: URL
    public let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        backendURL: URL,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        // Treat `backendURL` as the base of the FastAPI app (the same value
        // AGUIKit's `AgentClient` is initialised with). Append `/backend-tools`
        // — append works whether the base has a trailing slash or not.
        self.endpoint = backendURL.appendingPathComponent("backend-tools")
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func list() async throws -> [BackendToolDescriptor] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([BackendToolDescriptor].self, from: data)
    }
}
