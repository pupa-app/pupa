import Foundation

/// A stored value for one harness permission control. Persisted per harness in
/// `SettingsStore` and serialised into `RunAgentInput.state` under the control's
/// `key`. `bool` for a toggle, `string` for a choice, `stringSet` for a toolset
/// mute list.
public enum HarnessSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case string(String)
    case stringSet([String])

    private enum CodingKeys: String, CodingKey { case kind, bool, string, stringSet }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .bool))
        case "string": self = .string(try c.decode(String.self, forKey: .string))
        default: self = .stringSet(try c.decode([String].self, forKey: .stringSet))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v): try c.encode("bool", forKey: .kind); try c.encode(v, forKey: .bool)
        case .string(let v): try c.encode("string", forKey: .kind); try c.encode(v, forKey: .string)
        case .stringSet(let v): try c.encode("stringSet", forKey: .kind); try c.encode(v, forKey: .stringSet)
        }
    }
}

/// One permission control a harness advertises via `GET /harnesses`. The
/// Settings sheet renders these generically so tool/permission UI depends on
/// the active harness rather than being hardcoded to one loop's state keys.
///
/// `key` is the exact `RunAgentInput.state` key the value is echoed into (e.g.
/// `disabled_tools`, `shell_approval_disabled`, `claude_loop_native`). `type` is
/// one of `bool`, `choice`, `toolset`.
public struct HarnessPermissionControl: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bool, choice, toolset
    }

    public let key: String
    public let type: Kind
    public let label: String
    /// Present for `choice` controls — the selectable values in order.
    public let options: [String]?
    /// Default value: a Bool for `bool`, a String for `choice`. Absent for
    /// `toolset` (whose "default" is the empty mute set).
    public let defaultBool: Bool?
    public let defaultString: String?

    private enum CodingKeys: String, CodingKey {
        case key, type, label, options, `default`
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        type = try c.decode(Kind.self, forKey: .type)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        options = try c.decodeIfPresent([String].self, forKey: .options)
        // `default` is bool for `bool` controls, string for `choice`.
        defaultBool = try? c.decodeIfPresent(Bool.self, forKey: .default)
        defaultString = try? c.decodeIfPresent(String.self, forKey: .default)
    }

    public init(
        key: String, type: Kind, label: String,
        options: [String]? = nil, defaultBool: Bool? = nil, defaultString: String? = nil
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.options = options
        self.defaultBool = defaultBool
        self.defaultString = defaultString
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(type, forKey: .type)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(options, forKey: .options)
        if let defaultBool { try c.encode(defaultBool, forKey: .default) }
        else if let defaultString { try c.encode(defaultString, forKey: .default) }
    }
}

/// One agent harness the backend serves, as advertised by `GET /harnesses`.
/// Drives both the endpoint the app talks to (`/harnesses/{id}`) and the model
/// / tool / permission UI for the active backend connection.
public struct HarnessDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let isDefault: Bool
    public let models: [KnownLLMModel]
    public let tools: [BackendToolDescriptor]
    public let permissions: [HarnessPermissionControl]

    public init(
        id: String, label: String, isDefault: Bool,
        models: [KnownLLMModel], tools: [BackendToolDescriptor],
        permissions: [HarnessPermissionControl]
    ) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.models = models
        self.tools = tools
        self.permissions = permissions
    }
}

/// Tiny URLSession-backed fetcher for `GET /harnesses`. Mirrors
/// `BackendModelsClient` / `BackendToolsClient`; one round-trip returns every
/// harness's models, tools, and permission schema.
public struct BackendHarnessesClient: Sendable {
    public let endpoint: URL
    public let extraHeaders: [String: String]
    private let session: URLSession

    public init(
        backendURL: URL,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.endpoint = backendURL.appendingPathComponent("harnesses")
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func list() async throws -> [HarnessDescriptor] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decode(data)
    }

    /// Decode a `GET /harnesses` response body. Exposed (not just inlined in
    /// `list`) so the wire contract can be tested without a live session.
    public static func decode(_ data: Data) throws -> [HarnessDescriptor] {
        try JSONDecoder().decode([Wire].self, from: data).map { $0.toDescriptor() }
    }

    // Wire shapes mirror the FastAPI `GET /harnesses` document.
    private struct Wire: Decodable {
        let id: String
        let label: String
        let isDefault: Bool
        let models: [ModelEntry]
        let tools: [BackendToolDescriptor]
        let permissions: [HarnessPermissionControl]

        func toDescriptor() -> HarnessDescriptor {
            HarnessDescriptor(
                id: id,
                label: label,
                isDefault: isDefault,
                models: models.map {
                    KnownLLMModel(
                        id: "\($0.provider)/\($0.modelId)",
                        provider: $0.provider,
                        modelId: $0.modelId,
                        label: $0.label
                    )
                },
                tools: tools,
                permissions: permissions
            )
        }
    }

    private struct ModelEntry: Decodable {
        let provider: String
        let modelId: String
        let label: String
    }
}
