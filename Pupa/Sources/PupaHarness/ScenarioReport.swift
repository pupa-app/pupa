import Foundation
import AGUIKit
import PupaApp

/// What a turn did, in one readable object.
///
/// The point of the harness: after `Scenario.send`, an agent reads this instead
/// of guessing from logs. Covers all four surfaces a turn touches — the chat
/// transcript, the canvas, the on-disk recovery records, and the wire.
public struct ScenarioReport: Sendable {
    public let myApp: MyApp?
    public let threadId: String
    public let bubbles: [ChatBubble]
    /// Set when the turn died on the wire — a refused connection, a dropped
    /// stream, an HTTP error. A turn that produced no reply and no issue was
    /// never sent; one with an issue tells you why.
    public let connectionIssue: String?
    /// Raw POST bodies, one per round. Empty when a plain session drove the
    /// run — nothing intercepts the socket there.
    public let wire: [Data]
    public let root: URL

    public init(
        myApp: MyApp?,
        threadId: String,
        bubbles: [ChatBubble],
        connectionIssue: String? = nil,
        wire: [Data],
        root: URL
    ) {
        self.myApp = myApp
        self.threadId = threadId
        self.bubbles = bubbles
        self.connectionIssue = connectionIssue
        self.wire = wire
        self.root = root
    }

    // MARK: Derived views

    /// Every tool the app actually executed this session, in order.
    public var toolCalls: [ToolCallEntry] { bubbles.flatMap(\.toolEntries) }

    public var assistantText: String {
        bubbles.filter { $0.role == .assistant }.map(\.text)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The parked-dispatch journal (`dispatch/<threadId>.json`), if one exists.
    /// Present after a turn parks on a frontend tool; absent once it settles.
    public var journal: String? {
        let url = root.appendingPathComponent("dispatch", isDirectory: true)
            .appendingPathComponent("\(threadId).json")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The three transcript-snapshot fields that decide turn recovery.
    /// `turnInFlight: true` with no live stream is the tell for most
    /// regressions in that area — see docs/testing-turn-recovery.md.
    public var recovery: (turnInFlight: Bool, lastEventSeq: Int?, pendingDispatchAfterSeq: Int?)? {
        let url = root.appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("\(threadId).json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["turnInFlight"] as? Bool ?? false,
                object["lastEventSeq"] as? Int,
                object["pendingDispatchAfterSeq"] as? Int)
    }

    /// Each round's decoded request — what the model was actually shown.
    public var rounds: [RunAgentInput] {
        wire.compactMap { try? JSONDecoder().decode(RunAgentInput.self, from: $0) }
    }

    // MARK: Rendering

    /// Human/agent-readable dump. The default output of `PupaCtl`.
    public func text(includeWire: Bool = true) -> String {
        var out: [String] = []
        out.append("thread \(threadId)   root \(root.path)")
        if let connectionIssue { out.append("connection issue: \(connectionIssue)") }

        out.append("")
        out.append("── chat ──")
        for bubble in bubbles {
            let body = bubble.text.isEmpty ? "" : "  \(oneLine(bubble.text))"
            out.append("\(bubble.role.rawValue)\(body)")
            for entry in bubble.toolEntries {
                out.append("  · \(entry.name) [\(entry.state.rawValue)] "
                    + "\(oneLine(entry.argsJSON)) → \(oneLine(entry.resultText))")
            }
        }

        out.append("")
        out.append("── canvas ──")
        if let myApp {
            out.append("\(myApp.name) (\(myApp.typeId))  active=\(myApp.activeComponentId ?? "-")")
            for component in myApp.components {
                let mark = component.id == myApp.activeComponentId ? "*" : " "
                let lock = component.isLocked ? " [locked]" : ""
                out.append("\(mark) \(component.id)  \(component.name)\(lock)")
                if let summary = component.summary { out.append("    \(oneLine(summary))") }
            }
        } else {
            out.append("(no myApp)")
        }

        if let recovery {
            out.append("")
            out.append("── recovery ──")
            out.append("turnInFlight=\(recovery.turnInFlight) "
                + "lastEventSeq=\(recovery.lastEventSeq.map(String.init) ?? "-") "
                + "pendingDispatchAfterSeq=\(recovery.pendingDispatchAfterSeq.map(String.init) ?? "-")")
        }
        if let journal {
            out.append("journal: \(oneLine(journal))")
        }

        if includeWire, !rounds.isEmpty {
            out.append("")
            out.append("── wire ──")
            for (n, input) in rounds.enumerated() {
                out.append("round \(n + 1): \(input.messages.count) msgs, "
                    + "\(input.tools.count) tools, \(input.context.count) context")
                if let last = input.messages.last(where: { $0.role == .user }),
                   case .text(let text)? = last.content {
                    out.append("  last user: \(oneLine(text))")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Machine-readable form — `PupaCtl --json`, for asserting on a flow from
    /// a script rather than reading it.
    public func json() throws -> String {
        var object: [String: Any] = [
            "threadId": threadId,
            "root": root.path,
            "assistantText": assistantText,
            "connectionIssue": connectionIssue as Any,
            "bubbles": bubbles.map { ["role": $0.role.rawValue, "text": $0.text] },
            "toolCalls": toolCalls.map {
                ["name": $0.name, "state": $0.state.rawValue,
                 "args": $0.argsJSON, "result": $0.resultText]
            },
            "rounds": rounds.map {
                ["messages": $0.messages.count, "tools": $0.tools.count,
                 "context": $0.context.count]
            },
        ]
        if let myApp {
            object["myApp"] = [
                "name": myApp.name,
                "typeId": myApp.typeId,
                "activeComponentId": myApp.activeComponentId as Any,
                "components": myApp.components.map {
                    ["id": $0.id, "name": $0.name,
                     "summary": $0.summary as Any, "isLocked": $0.isLocked]
                },
            ]
        }
        if let recovery {
            object["recovery"] = [
                "turnInFlight": recovery.turnInFlight,
                "lastEventSeq": recovery.lastEventSeq as Any,
                "pendingDispatchAfterSeq": recovery.pendingDispatchAfterSeq as Any,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func oneLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
