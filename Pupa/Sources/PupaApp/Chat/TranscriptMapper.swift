import Foundation

/// Maps a flat `[TranscriptMessage]` list (from the backend transcript endpoint)
/// into the `[ChatBubble]` shape the chat UI renders.
///
/// Mapping rules:
/// - `"human"` messages → `.user` bubble.
/// - `"ai"` messages with text and no tool calls → `.assistant` bubble.
/// - `"ai"` messages with tool calls, plus the immediately-following `"tool"`
///   messages that resolve each call → one `.toolRound` bubble grouping all
///   the `ToolCallEntry` pairs. A final `"ai"` message after the tool round
///   renders as a separate `.assistant` bubble.
///
/// Transient local-only bubbles (`humanQuestion`, `shellApproval`) are not
/// reconstructed — they appear as tool rounds, which is acceptable for history.
enum TranscriptMapper {
    static func bubbles(from messages: [TranscriptMessage]) -> [ChatBubble] {
        var result: [ChatBubble] = []
        var index = 0

        while index < messages.count {
            let msg = messages[index]

            switch msg.role {
            case "human":
                result.append(ChatBubble(
                    id: msg.id ?? UUID().uuidString,
                    role: .user,
                    text: msg.content
                ))
                index += 1

            case "ai" where !msg.toolCalls.isEmpty:
                // Collect the matching tool result messages that follow.
                var entries: [ToolCallEntry] = []
                var chartSnapshots: [ChatChartSnapshot] = []
                let callsById = Dictionary(uniqueKeysWithValues: msg.toolCalls.map { ($0.id, $0) })
                var toolIndex = index + 1
                var consumed = Set<String>()
                while toolIndex < messages.count, messages[toolIndex].role == "tool" {
                    let toolMsg = messages[toolIndex]
                    if let callId = toolMsg.toolCallId,
                       let call = callsById[callId],
                       !consumed.contains(callId) {
                        consumed.insert(callId)
                        entries.append(ToolCallEntry(
                            id: callId,
                            name: call.name,
                            argsJSON: prettyArgs(call.args),
                            resultText: toolMsg.content,
                            state: .done
                        ))
                        // Rebuild any chat-embedded chart from its result so
                        // the snapshot survives a transcript reload.
                        if call.name == "embedComponent",
                           let snap = chartSnapshot(fromResult: toolMsg.content) {
                            chartSnapshots.append(snap)
                        }
                    }
                    toolIndex += 1
                }
                // Any tool calls without a matching tool message go in as pending.
                for call in msg.toolCalls where !consumed.contains(call.id) {
                    entries.append(ToolCallEntry(
                        id: call.id,
                        name: call.name,
                        argsJSON: prettyArgs(call.args),
                        resultText: "",
                        state: .done
                    ))
                }
                result.append(ChatBubble(
                    id: msg.id ?? UUID().uuidString,
                    role: .toolRound,
                    text: "",
                    toolEntries: entries
                ))
                for snap in chartSnapshots {
                    result.append(ChatBubble(role: .assistant, chartSnapshot: snap))
                }
                index = toolIndex

            case "ai":
                result.append(ChatBubble(
                    id: msg.id ?? UUID().uuidString,
                    role: .assistant,
                    text: msg.content
                ))
                index += 1

            default:
                // Skip orphan tool messages (already consumed above) or unknown roles.
                index += 1
            }
        }

        return result
    }

    /// Decode an `embedComponent` result string and pull out its
    /// `chartSnapshot` (present only for hostKind "chat").
    private static func chartSnapshot(fromResult content: String) -> ChatChartSnapshot? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snap = obj["chartSnapshot"],
              let snapData = try? JSONSerialization.data(withJSONObject: snap) else { return nil }
        return try? JSONDecoder().decode(ChatChartSnapshot.self, from: snapData)
    }

    private static func prettyArgs(_ args: [String: AnyCodable]) -> String {
        guard let data = try? JSONEncoder().encode(args),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
