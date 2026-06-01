import Foundation

/// One conversation entry in a scope's thread list.
///
/// Each thread maps to a backend LangGraph threadId. Threads are ordered by
/// creation time and stored in `MyApp.threads` / `MyAppStore.memoryThreads`.
/// The active one is tracked by `MyApp.currentThreadId` /
/// `MyAppStore.memoryCurrentThreadId`.
public struct ChatThread: Codable, Hashable, Identifiable, Sendable {
    /// Backend LangGraph threadId (UUID string).
    public let id: String
    /// First ~6 words of the first user message. Empty until the first send.
    public var title: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}
