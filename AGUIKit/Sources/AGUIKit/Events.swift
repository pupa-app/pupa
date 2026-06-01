import Foundation

/// One server-sent AG-UI event. Discriminated by the wire-level `type` string.
///
/// Only the events we actively use are decoded into typed cases. Everything
/// else is preserved as `.unknown(type:raw:)` so callers can handle them or
/// ignore them without us silently losing data.
public enum AgentEvent: Sendable, Hashable {
    case runStarted(RunStarted)
    case runFinished(RunFinished)
    case runError(RunError)

    case textMessageStart(TextMessageStart)
    case textMessageContent(TextMessageContent)
    case textMessageEnd(TextMessageEnd)

    case toolCallStart(ToolCallStart)
    case toolCallArgs(ToolCallArgs)
    case toolCallEnd(ToolCallEnd)
    case toolCallResult(ToolCallResult)

    case stateSnapshot(StateSnapshot)
    case stateDelta(StateDelta)
    case messagesSnapshot(MessagesSnapshot)

    case stepStarted(StepStarted)
    case stepFinished(StepFinished)

    case raw(Raw)
    case custom(Custom)

    case unknown(type: String, raw: AnyJSON)
}

// MARK: - Per-event payloads

public extension AgentEvent {
    struct RunStarted: Codable, Sendable, Hashable {
        public var threadId: String
        public var runId: String
        public var parentRunId: String?
    }
    struct RunFinished: Codable, Sendable, Hashable {
        public var threadId: String
        public var runId: String
        public var result: AnyJSON?
    }
    struct RunError: Codable, Sendable, Hashable {
        public var message: String
        public var code: String?
    }

    struct TextMessageStart: Codable, Sendable, Hashable {
        public var messageId: String
        public var role: String?
        public var name: String?
    }
    struct TextMessageContent: Codable, Sendable, Hashable {
        public var messageId: String
        public var delta: String
    }
    struct TextMessageEnd: Codable, Sendable, Hashable {
        public var messageId: String
    }

    struct ToolCallStart: Codable, Sendable, Hashable {
        public var toolCallId: String
        public var toolCallName: String
        public var parentMessageId: String?
    }
    struct ToolCallArgs: Codable, Sendable, Hashable {
        public var toolCallId: String
        public var delta: String
    }
    struct ToolCallEnd: Codable, Sendable, Hashable {
        public var toolCallId: String
    }
    struct ToolCallResult: Codable, Sendable, Hashable {
        public var messageId: String
        public var toolCallId: String
        public var content: String
        public var role: String?
    }

    struct StateSnapshot: Codable, Sendable, Hashable {
        public var snapshot: AnyJSON
    }
    struct StateDelta: Codable, Sendable, Hashable {
        public var delta: AnyJSON
    }
    struct MessagesSnapshot: Codable, Sendable, Hashable {
        public var messages: [AgentMessage]
    }

    struct StepStarted: Codable, Sendable, Hashable {
        public var stepName: String
    }
    struct StepFinished: Codable, Sendable, Hashable {
        public var stepName: String
    }

    struct Raw: Codable, Sendable, Hashable {
        public var event: AnyJSON
        public var source: String?
    }
    struct Custom: Codable, Sendable, Hashable {
        public var name: String
        public var value: AnyJSON
    }
}

// MARK: - Decoding

extension AgentEvent: Decodable {
    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: CodingKeys.self)
        let type = try typeContainer.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()

        switch type {
        case "RUN_STARTED":         self = .runStarted(try single.decode(RunStarted.self))
        case "RUN_FINISHED":        self = .runFinished(try single.decode(RunFinished.self))
        case "RUN_ERROR":           self = .runError(try single.decode(RunError.self))

        case "TEXT_MESSAGE_START":   self = .textMessageStart(try single.decode(TextMessageStart.self))
        case "TEXT_MESSAGE_CONTENT": self = .textMessageContent(try single.decode(TextMessageContent.self))
        case "TEXT_MESSAGE_END":     self = .textMessageEnd(try single.decode(TextMessageEnd.self))

        case "TOOL_CALL_START":      self = .toolCallStart(try single.decode(ToolCallStart.self))
        case "TOOL_CALL_ARGS":       self = .toolCallArgs(try single.decode(ToolCallArgs.self))
        case "TOOL_CALL_END":        self = .toolCallEnd(try single.decode(ToolCallEnd.self))
        case "TOOL_CALL_RESULT":     self = .toolCallResult(try single.decode(ToolCallResult.self))

        case "STATE_SNAPSHOT":       self = .stateSnapshot(try single.decode(StateSnapshot.self))
        case "STATE_DELTA":          self = .stateDelta(try single.decode(StateDelta.self))
        case "MESSAGES_SNAPSHOT":    self = .messagesSnapshot(try single.decode(MessagesSnapshot.self))

        case "STEP_STARTED":         self = .stepStarted(try single.decode(StepStarted.self))
        case "STEP_FINISHED":        self = .stepFinished(try single.decode(StepFinished.self))

        case "RAW":                  self = .raw(try single.decode(Raw.self))
        case "CUSTOM":               self = .custom(try single.decode(Custom.self))

        default:
            let raw = try single.decode(AnyJSON.self)
            self = .unknown(type: type, raw: raw)
        }
    }
}
