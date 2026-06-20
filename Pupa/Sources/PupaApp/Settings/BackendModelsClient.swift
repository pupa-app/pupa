import Foundation

/// Tiny URLSession-backed fetcher for the model registry. Mirrors
/// `BackendToolsClient` — talks to the sibling `GET /models` REST route.
public struct BackendModelsClient: Sendable {
    public let endpoint: URL
    public let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        backendURL: URL,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.endpoint = backendURL.appendingPathComponent("models")
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func list() async throws -> [KnownLLMModel] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let entries = try JSONDecoder().decode([ModelEntry].self, from: data)
        return entries.map { entry in
            KnownLLMModel(
                id: "\(entry.provider)/\(entry.modelId)",
                provider: entry.provider,
                modelId: entry.modelId,
                label: entry.label
            )
        }
    }

    private struct ModelEntry: Decodable {
        let provider: String
        let modelId: String
        let label: String
    }
}
