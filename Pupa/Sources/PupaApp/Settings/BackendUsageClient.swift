import Foundation

/// Token + cost totals for one thread, as reported by the backend.
/// Mirrors `ThreadUsage` in
/// `backend/pupa_backend/harnesses/langgraph/db/schemas.py`.
///
/// `totalTokens` / `costUSD` are `nil` when the backend has no usage figures
/// for the thread — how it collects them is its own business. `fingerprint`
/// is the latest checkpoint_id and changes only on a new turn.
public struct ThreadUsage: Decodable, Sendable, Hashable {
    public let threadId: String
    public let totalTokens: Int?
    public let costUSD: Double?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let fingerprint: String?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case totalTokens = "total_tokens"
        case costUSD = "cost_usd"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case fingerprint
    }

    public init(
        threadId: String,
        totalTokens: Int? = nil,
        costUSD: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        fingerprint: String? = nil
    ) {
        self.threadId = threadId
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.fingerprint = fingerprint
    }
}

/// Prompt-cache breakdown for one thread. Mirrors `ThreadCacheUsage` in
/// `backend/pupa_backend/harnesses/langgraph/db/schemas.py`. Heavier for the
/// backend to compute — fetched on demand, not in the bulk paint.
public struct ThreadCacheUsage: Decodable, Sendable, Hashable {
    public let threadId: String
    public let inputTotal: Int?
    public let inputCacheRead: Int?
    public let inputCacheCreation: Int?
    public let cacheReadPct: Double?
    public let fingerprint: String?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case inputTotal = "input_total"
        case inputCacheRead = "input_cache_read"
        case inputCacheCreation = "input_cache_creation"
        case cacheReadPct = "cache_read_pct"
        case fingerprint
    }

    public init(
        threadId: String,
        inputTotal: Int? = nil,
        inputCacheRead: Int? = nil,
        inputCacheCreation: Int? = nil,
        cacheReadPct: Double? = nil,
        fingerprint: String? = nil
    ) {
        self.threadId = threadId
        self.inputTotal = inputTotal
        self.inputCacheRead = inputCacheRead
        self.inputCacheCreation = inputCacheCreation
        self.cacheReadPct = cacheReadPct
        self.fingerprint = fingerprint
    }
}

/// Fetches batched per-thread usage from `POST /db/threads/usage`.
/// One call covers many threads — payloads per thread are tiny, so the Agents
/// dashboard sends every visible thread id in a single request.
/// Mirrors `BackendThreadsClient`'s URLSession + auth-header pattern.
public struct BackendUsageClient: Sendable {
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

    private struct BatchResponse: Decodable {
        let usage: [String: ThreadUsage]
    }

    private struct CacheBatchResponse: Decodable {
        let usage: [String: ThreadCacheUsage]
    }

    /// Returns `[threadId: ThreadUsage]`. Threads with no row are simply absent.
    public func fetchUsage(threadIds: [String]) async throws -> [String: ThreadUsage] {
        let data = try await post(path: "usage", threadIds: threadIds)
        guard let data else { return [:] }
        return try JSONDecoder().decode(BatchResponse.self, from: data).usage
    }

    /// On-demand prompt-cache breakdown. Heavier server-side — call when a
    /// detail view opens, not on every dashboard paint.
    public func fetchCache(threadIds: [String]) async throws -> [String: ThreadCacheUsage] {
        let data = try await post(path: "usage/cache", threadIds: threadIds)
        guard let data else { return [:] }
        return try JSONDecoder().decode(CacheBatchResponse.self, from: data).usage
    }

    /// POST `{thread_ids:[...]}` to `db/threads/<path>`. Returns `nil` for an
    /// empty id list (no request made).
    private func post(path: String, threadIds: [String]) async throws -> Data? {
        guard !threadIds.isEmpty else { return nil }
        var url = backendURL.appendingPathComponent("db").appendingPathComponent("threads")
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["thread_ids": threadIds])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
