import Foundation
import Testing
@testable import AGUIKit

@Suite("Event decoding")
struct EventDecodingTests {
    private func decode(_ json: String) throws -> AgentEvent {
        try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
    }

    @Test func runStarted() throws {
        let ev = try decode(#"{"type":"RUN_STARTED","threadId":"t","runId":"r"}"#)
        guard case .runStarted(let s) = ev else { Issue.record("wrong case"); return }
        #expect(s.threadId == "t")
        #expect(s.runId == "r")
    }

    @Test func textMessageSequence() throws {
        let start = try decode(#"{"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"}"#)
        let chunk = try decode(#"{"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Hello"}"#)
        let end = try decode(#"{"type":"TEXT_MESSAGE_END","messageId":"m1"}"#)
        guard case .textMessageStart(let s) = start,
              case .textMessageContent(let c) = chunk,
              case .textMessageEnd(let e) = end else {
            Issue.record("wrong cases"); return
        }
        #expect(s.messageId == "m1")
        #expect(c.delta == "Hello")
        #expect(e.messageId == "m1")
    }

    @Test func toolCallSequence() throws {
        let start = try decode(#"{"type":"TOOL_CALL_START","toolCallId":"c1","toolCallName":"addTrackerItem"}"#)
        let args = try decode(#"{"type":"TOOL_CALL_ARGS","toolCallId":"c1","delta":"{\"item\":"}"#)
        let end = try decode(#"{"type":"TOOL_CALL_END","toolCallId":"c1"}"#)
        guard case .toolCallStart(let s) = start,
              case .toolCallArgs(let a) = args,
              case .toolCallEnd(let e) = end else {
            Issue.record("wrong cases"); return
        }
        #expect(s.toolCallName == "addTrackerItem")
        #expect(a.delta == "{\"item\":")
        #expect(e.toolCallId == "c1")
    }

    @Test func runFinished() throws {
        let ev = try decode(#"{"type":"RUN_FINISHED","threadId":"t","runId":"r"}"#)
        if case .runFinished = ev {} else { Issue.record("wrong case") }
    }

    @Test func unknownTypePreserved() throws {
        let ev = try decode(#"{"type":"FUTURE_FEATURE","payload":{"x":1}}"#)
        guard case .unknown(let type, _) = ev else { Issue.record("wrong case"); return }
        #expect(type == "FUTURE_FEATURE")
    }

    @Test func messagesSnapshot() throws {
        let json = #"""
        {"type":"MESSAGES_SNAPSHOT","messages":[
          {"id":"u1","role":"user","content":"hi"},
          {"id":"a1","role":"assistant","content":"hello"}
        ]}
        """#
        let ev = try decode(json)
        guard case .messagesSnapshot(let snap) = ev else { Issue.record(); return }
        #expect(snap.messages.count == 2)
        #expect(snap.messages[0].role == .user)
        #expect(snap.messages[1].contentText == "hello")
    }

    @Test func runAgentInputUsesCamelCase() throws {
        let input = RunAgentInput(
            threadId: "t",
            runId: "r",
            messages: [.user("hi")],
            tools: [
                ToolDescriptor(
                    name: "addTrackerItem",
                    description: "Add an item",
                    parameters: ["type": "object", "properties": ["item": ["type": "object"]]]
                )
            ],
            context: [AgentContextEntry(description: "live state", value: "{}")]
        )
        let data = try JSONEncoder().encode(input)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("threadId"))
        #expect(s.contains("forwardedProps"))
        #expect(!s.contains("thread_id"))
    }
}
