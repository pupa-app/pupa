import Foundation

/// A tool descriptor sent to the agent in `RunAgentInput.tools`.
///
/// `parameters` is a JSON Schema fragment describing the tool's argument
/// shape. The same schema is what the agent's LLM sees when deciding whether
/// and how to call the tool.
public struct ToolDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var parameters: AnyJSON

    public init(name: String, description: String, parameters: AnyJSON) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A tool the client knows how to execute locally. The descriptor is what the
/// agent sees; the handler is what runs when the agent picks the tool.
public struct ClientTool: Sendable {
    public let descriptor: ToolDescriptor
    /// Async handler that takes the parsed arguments and returns a JSON-able
    /// result. The result is serialised as a string and sent back as the
    /// `ToolMessage.content` for the next agent round.
    public let handler: @Sendable (AnyJSON) async throws -> AnyJSON
    /// When `true`, `AgentSession.runLoop` may dispatch this tool's handler
    /// concurrently with other parallel-safe handlers in the same round
    /// (the agent batched multiple `tool_calls` into one assistant turn).
    /// Results are still appended to the message history in submission order
    /// so the next round POSTs a deterministic conversation; only handler
    /// execution overlaps. Default `false` — opt-in because most handlers
    /// mutate shared state (e.g. a canvas) and rely on sequential, in-order
    /// execution to preserve user-visible ordering.
    public let parallelSafe: Bool
    /// Declares this tool as non-mutating. Read-only tools are exempt from
    /// host-side write gating (e.g. a locked canvas component); mutating
    /// tools (the default) are subject to it. AGUIKit itself does not act on
    /// this flag — the host decides how to gate — but every tool declaring
    /// its read/write intent keeps that gating declarative and central.
    public let readOnly: Bool

    public init(
        descriptor: ToolDescriptor,
        parallelSafe: Bool = false,
        readOnly: Bool = false,
        handler: @Sendable @escaping (AnyJSON) async throws -> AnyJSON
    ) {
        self.descriptor = descriptor
        self.parallelSafe = parallelSafe
        self.readOnly = readOnly
        self.handler = handler
    }
}
