import Foundation

/// One conversation entry in a scope's thread list.
///
/// Each thread maps to a backend threadId. Threads are ordered by
/// creation time and stored in `MyApp.threads` / `MyAppStore.memoryThreads`.
/// The active one is tracked by `MyApp.currentThreadId` /
/// `MyAppStore.memoryCurrentThreadId`.
public struct ChatThread: Codable, Hashable, Identifiable, Sendable {
    /// Backend threadId (UUID string).
    public let id: String
    /// First ~6 words of the first user message. Empty until the first send.
    public var title: String
    public let createdAt: Date
    /// Per-thread LLM override provider ("bedrock" | "anthropic" | …). Paired
    /// with `llmModel` — both present or the override doesn't apply. `nil` →
    /// the thread inherits its scope's default (MyApp / orchestrator).
    public var llmProvider: String?
    /// Per-thread LLM override logical model id (e.g. "claude-sonnet-4-6").
    public var llmModel: String?

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        createdAt: Date = Date(),
        llmProvider: String? = nil,
        llmModel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }
}
