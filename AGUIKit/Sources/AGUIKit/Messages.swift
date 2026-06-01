import Foundation

/// A message in the agent's conversation history. The wire encoding follows
/// AG-UI's discriminated-union form: every message has an `id`, `role`, and
/// optional shared fields (`content`, `name`), plus role-specific fields.
///
/// Messages are encoded as plain JSON objects (not wrapped). Decoding switches
/// on the `role` field; encoding emits role-specific keys.
public struct AgentMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
        case system
        case developer
    }

    public var id: String
    public var role: Role
    /// Required for system/developer/tool, optional on assistant (when
    /// `toolCalls` is present), optional on user. User messages may carry
    /// either plain text (`.text`) or a list of multimodal parts (`.parts`,
    /// e.g. text + image). All other roles use `.text` only.
    public var content: MessageContent?
    public var name: String?
    /// Assistant-only: the tool calls this message requested.
    public var toolCalls: [ToolCall]?
    /// Tool-only: which tool call this message answers.
    public var toolCallId: String?

    public init(
        id: String = UUID().uuidString,
        role: Role,
        content: MessageContent? = nil,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// Plain-text accessor for the common case where callers don't care about
    /// multimodal parts (assistant streaming, tool results, chat history).
    /// Returns nil if `content` is `.parts` (call sites that need to render
    /// non-text parts should switch on `content` directly).
    public var contentText: String? {
        switch content {
        case .text(let s)?: return s
        case .parts?, nil: return nil
        }
    }

    // MARK: - Convenience constructors

    public static func user(_ content: String, id: String = UUID().uuidString) -> AgentMessage {
        AgentMessage(id: id, role: .user, content: .text(content))
    }

    /// Build a user message that may carry an inline image alongside text.
    /// When `image` is nil, encodes as plain text on the wire (back-compat).
    /// When present, encodes as a 2-element parts array: text + image.
    public static func user(
        text: String,
        image: (data: Data, mimeType: String)?,
        id: String = UUID().uuidString
    ) -> AgentMessage {
        guard let image else {
            return AgentMessage(id: id, role: .user, content: .text(text))
        }
        let parts: [ContentPart] = [
            .text(text),
            .image(.data(base64: image.data.base64EncodedString(), mimeType: image.mimeType)),
        ]
        return AgentMessage(id: id, role: .user, content: .parts(parts))
    }

    public static func assistant(_ content: String, id: String = UUID().uuidString) -> AgentMessage {
        AgentMessage(id: id, role: .assistant, content: .text(content))
    }
    public static func assistantToolCalls(_ calls: [ToolCall], id: String = UUID().uuidString, content: String? = nil) -> AgentMessage {
        AgentMessage(id: id, role: .assistant, content: content.map { .text($0) }, toolCalls: calls)
    }
    public static func tool(toolCallId: String, content: String, id: String = UUID().uuidString) -> AgentMessage {
        AgentMessage(id: id, role: .tool, content: .text(content), toolCallId: toolCallId)
    }

    // MARK: - Codable (camelCase)

    private enum CodingKeys: String, CodingKey {
        case id, role, content, name
        case toolCalls
        case toolCallId
    }
}

/// A message's content payload. Either a single text blob (the common case
/// for every role) or, for user messages, a list of multimodal parts (text
/// fragments + images, etc.). Wire encoding mirrors AG-UI's
/// `Union[str, List[InputContent]]`: `.text(s)` becomes a bare JSON string,
/// `.parts([...])` becomes a JSON array.
public enum MessageContent: Codable, Hashable, Sendable {
    case text(String)
    case parts([ContentPart])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .text(s)
            return
        }
        if let parts = try? c.decode([ContentPart].self) {
            self = .parts(parts)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "MessageContent must be a string or an array of content parts."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):
            try c.encode(s)
        case .parts(let parts):
            try c.encode(parts)
        }
    }
}

/// One element of a multimodal user message's content array. Mirrors AG-UI's
/// `InputContent` discriminated union; current cases cover text + image. Other
/// AG-UI media types (audio/video/document) aren't surfaced yet — they'd
/// decode as `.unknown` so receivers don't crash on forward-compatible input.
public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)
    case image(ImageSource)
    /// Forward-compatible bucket for any AG-UI part type AGUIKit doesn't model
    /// yet (audio, video, document, …). Preserves the raw discriminator so
    /// re-encoding round-trips, but the payload is opaque to consumers.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let s = try c.decode(String.self, forKey: .text)
            self = .text(s)
        case "image":
            let src = try c.decode(ImageSource.self, forKey: .source)
            self = .image(src)
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let src):
            try c.encode("image", forKey: .type)
            try c.encode(src, forKey: .source)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

/// Image payload reference — either inline base64 data or a URL. Mirrors
/// AG-UI's `InputContentSource` discriminated union; field names use camelCase
/// (`mimeType`) since AG-UI's Pydantic models accept both casings via
/// `populate_by_name`, and the rest of AGUIKit's wire encoding is camelCase.
public enum ImageSource: Codable, Hashable, Sendable {
    case data(base64: String, mimeType: String)
    case url(String, mimeType: String?)

    private enum CodingKeys: String, CodingKey {
        case type, value, mimeType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "data":
            let value = try c.decode(String.self, forKey: .value)
            let mime = try c.decode(String.self, forKey: .mimeType)
            self = .data(base64: value, mimeType: mime)
        case "url":
            let value = try c.decode(String.self, forKey: .value)
            let mime = try c.decodeIfPresent(String.self, forKey: .mimeType)
            self = .url(value, mimeType: mime)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown image source type '\(type)'."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .data(let base64, let mime):
            try c.encode("data", forKey: .type)
            try c.encode(base64, forKey: .value)
            try c.encode(mime, forKey: .mimeType)
        case .url(let value, let mime):
            try c.encode("url", forKey: .type)
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(mime, forKey: .mimeType)
        }
    }
}

/// A function tool call requested by the assistant (modelled after OpenAI's
/// shape, which AG-UI inherits).
public struct ToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var function: ToolCallFunction

    public init(id: String, type: String = "function", function: ToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ToolCallFunction: Codable, Hashable, Sendable {
    public var name: String
    /// JSON-encoded string of arguments. Per the AG-UI spec, this is a JSON
    /// string, not a JSON object — the LLM emits it that way and we forward.
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }

    /// Parse `arguments` as JSON into an `AnyJSON` for handler dispatch.
    public func parsedArguments() throws -> AnyJSON {
        guard let data = arguments.data(using: .utf8) else {
            return .object([:])
        }
        if data.isEmpty { return .object([:]) }
        return try JSONDecoder().decode(AnyJSON.self, from: data)
    }
}
