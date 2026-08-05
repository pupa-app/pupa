import Foundation

/// One message from the normalized transcript endpoint.
/// Mirrors the backend's `TranscriptMessage` schema.
public struct TranscriptMessage: Decodable, Sendable {
    public let id: String?
    /// LangChain role: `"human"` | `"ai"` | `"tool"`.
    public let role: String
    public let content: String
    public let toolCalls: [TranscriptToolCall]
    public let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

/// One tool call entry inside an AI message.
public struct TranscriptToolCall: Decodable, Sendable {
    public let id: String
    public let name: String
    public let args: [String: AnyCodable]
}

/// Type-erased Codable value for tool call args.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v; return }
        value = ()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        default: try c.encodeNil()
        }
    }
}

/// Fetches the normalized transcript for a thread from the backend.
/// Mirrors `BackendToolsClient`'s URLSession + auth-header pattern.
public struct BackendThreadsClient: Sendable {
    private let backendURL: URL
    private let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        backendURL: URL,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.backendURL = backendURL
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func fetchTranscript(threadId: String) async throws -> [TranscriptMessage] {
        let url = backendURL
            .appendingPathComponent("db")
            .appendingPathComponent("threads")
            .appendingPathComponent(threadId)
            .appendingPathComponent("messages")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([TranscriptMessage].self, from: data)
    }
}
