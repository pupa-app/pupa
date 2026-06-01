import Foundation

/// Registry of locally-executable tools the agent can call. Hand the
/// `descriptors` to `RunAgentInput.tools` each turn; resolve a tool by name
/// when a `TOOL_CALL_END` event arrives whose call falls in the registry.
public final class ToolRegistry: @unchecked Sendable {
    private var byName: [String: ClientTool] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ tool: ClientTool) {
        lock.lock(); defer { lock.unlock() }
        byName[tool.descriptor.name] = tool
    }

    public func remove(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        byName.removeValue(forKey: name)
    }

    public func resolve(_ name: String) -> ClientTool? {
        lock.lock(); defer { lock.unlock() }
        return byName[name]
    }

    /// Snapshot of every registered tool's descriptor — what to send in
    /// `RunAgentInput.tools` on each round.
    public var descriptors: [ToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return byName.values.map(\.descriptor)
    }
}
