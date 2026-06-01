import Foundation

/// A single context entry (description + JSON-stringified value), pushed to
/// the agent every turn. Equivalent to React's `useAgentContext` calls.
public struct AgentContextEntry: Codable, Hashable, Sendable {
    public var description: String
    public var value: String

    public init(description: String, value: String) {
        self.description = description
        self.value = value
    }
}

/// The body POSTed to the AG-UI endpoint to run one round of the agent.
/// Field names are camelCased on the wire (the backend's Pydantic models use
/// `alias_generator=to_camel`).
public struct RunAgentInput: Codable, Sendable {
    public var threadId: String
    public var runId: String
    public var parentRunId: String?
    public var state: AnyJSON
    public var messages: [AgentMessage]
    public var tools: [ToolDescriptor]
    public var context: [AgentContextEntry]
    public var forwardedProps: AnyJSON

    public init(
        threadId: String,
        runId: String = UUID().uuidString,
        parentRunId: String? = nil,
        state: AnyJSON = .null,
        messages: [AgentMessage],
        tools: [ToolDescriptor],
        context: [AgentContextEntry],
        forwardedProps: AnyJSON = .object([:])
    ) {
        self.threadId = threadId
        self.runId = runId
        self.parentRunId = parentRunId
        self.state = state
        self.messages = messages
        self.tools = tools
        self.context = context
        self.forwardedProps = forwardedProps
    }
}
