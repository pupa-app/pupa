import Foundation
import Testing
@testable import AGUIKit

@Suite("Message multimodal content")
struct MessageContentTests {
    private func encode(_ msg: AgentMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(msg)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func decode(_ json: String) throws -> AgentMessage {
        try JSONDecoder().decode(AgentMessage.self, from: Data(json.utf8))
    }

    // MARK: - Plain text (back-compat with v0.0.6 wire shape)

    @Test func textMessageEncodesAsBareString() throws {
        let msg = AgentMessage.user("hi", id: "u1")
        let json = try encode(msg)
        #expect(json.contains(#""content":"hi""#))
        #expect(!json.contains(#""content":[""#))
    }

    @Test func legacyTextPayloadDecodesIntoTextCase() throws {
        let json = #"{"id":"u1","role":"user","content":"hi"}"#
        let msg = try decode(json)
        #expect(msg.contentText == "hi")
        if case .text(let s) = msg.content {
            #expect(s == "hi")
        } else {
            Issue.record("expected .text case for legacy payload")
        }
    }

    @Test func textRoundTrip() throws {
        let original = AgentMessage.user("round trip", id: "u1")
        let decoded = try decode(try encode(original))
        #expect(decoded == original)
    }

    // MARK: - Multimodal (text + image)

    @Test func userWithImageEncodesAsPartsArray() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0xCC]
        let data = Data(bytes)
        let msg = AgentMessage.user(
            text: "what's this?",
            image: (data: data, mimeType: "image/jpeg"),
            id: "u1"
        )
        let json = try encode(msg)
        // Parts array with a text part and an image part
        #expect(json.contains(#""type":"text""#))
        #expect(json.contains(#""text":"what's this?""#))
        #expect(json.contains(#""type":"image""#))
        #expect(json.contains(#""mimeType":"image\/jpeg""#) || json.contains(#""mimeType":"image/jpeg""#))
        #expect(json.contains(#""value":"\#(data.base64EncodedString())""#))
    }

    @Test func multimodalRoundTrip() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let original = AgentMessage.user(
            text: "describe this",
            image: (data: data, mimeType: "image/png"),
            id: "u2"
        )
        let decoded = try decode(try encode(original))
        #expect(decoded == original)
        #expect(decoded.contentText == nil)  // .parts → contentText returns nil
        if case .parts(let parts) = decoded.content {
            #expect(parts.count == 2)
            if case .text(let t) = parts[0] { #expect(t == "describe this") }
            else { Issue.record("expected .text first part") }
            if case .image(.data(let b64, let mime)) = parts[1] {
                #expect(b64 == data.base64EncodedString())
                #expect(mime == "image/png")
            } else {
                Issue.record("expected .image(.data) second part")
            }
        } else {
            Issue.record("expected .parts case")
        }
    }

    @Test func userImageNilFallsBackToText() throws {
        let msg = AgentMessage.user(text: "no attachment", image: nil, id: "u3")
        if case .text(let s) = msg.content {
            #expect(s == "no attachment")
        } else {
            Issue.record("expected .text fallback when image is nil")
        }
    }

    @Test func unknownPartTypeRoundTripsAsUnknown() throws {
        let json = #"""
        {"id":"u4","role":"user","content":[{"type":"text","text":"hi"},{"type":"audio","source":{"type":"data","value":"AAA=","mimeType":"audio/mpeg"}}]}
        """#
        let decoded = try decode(json)
        if case .parts(let parts) = decoded.content {
            #expect(parts.count == 2)
            if case .unknown(let t) = parts[1] {
                #expect(t == "audio")
            } else {
                Issue.record("expected unknown('audio') for unmodelled part type")
            }
        } else {
            Issue.record("expected .parts")
        }
    }

    // MARK: - Other roles still work after the type change

    @Test func toolMessageContentStillCarriesText() throws {
        let msg = AgentMessage.tool(toolCallId: "call-1", content: "{\"ok\":true}", id: "t1")
        let json = try encode(msg)
        #expect(json.contains(#""content":"{\"ok\":true}""#))
        let decoded = try decode(json)
        #expect(decoded.contentText == #"{"ok":true}"#)
        #expect(decoded.toolCallId == "call-1")
    }

    @Test func assistantToolCallsRoundTrip() throws {
        let calls = [
            ToolCall(id: "c1", function: ToolCallFunction(name: "addItem", arguments: "{}"))
        ]
        let original = AgentMessage.assistantToolCalls(calls, id: "a1", content: "calling…")
        let decoded = try decode(try encode(original))
        #expect(decoded == original)
        #expect(decoded.contentText == "calling…")
        #expect(decoded.toolCalls?.first?.function.name == "addItem")
    }
}
