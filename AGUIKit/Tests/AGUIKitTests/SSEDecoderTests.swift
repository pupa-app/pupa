import Foundation
import Testing
@testable import AGUIKit

@Suite("SSEDecoder")
struct SSEDecoderTests {
    @Test func singleFrame() {
        let decoder = SSEDecoder()
        let frames = decoder.feed(Data("data: hello\n\n".utf8))
        #expect(frames == [SSEFrame(data: "hello")])
    }

    @Test func multiDataLines() {
        let decoder = SSEDecoder()
        let frames = decoder.feed(Data("data: line1\ndata: line2\n\n".utf8))
        #expect(frames == [SSEFrame(data: "line1\nline2")])
    }

    @Test func eventAndIdFields() {
        let decoder = SSEDecoder()
        let frames = decoder.feed(Data("event: ping\nid: 7\ndata: {}\n\n".utf8))
        #expect(frames == [SSEFrame(event: "ping", id: "7", data: "{}")])
    }

    @Test func crlf() {
        let decoder = SSEDecoder()
        let frames = decoder.feed(Data("data: a\r\ndata: b\r\n\r\n".utf8))
        #expect(frames == [SSEFrame(data: "a\nb")])
    }

    @Test func commentLineIgnored() {
        let decoder = SSEDecoder()
        let frames = decoder.feed(Data(": this is a comment\ndata: ok\n\n".utf8))
        #expect(frames == [SSEFrame(data: "ok")])
    }

    @Test func splitFeedAcrossBoundary() {
        let decoder = SSEDecoder()
        var frames = decoder.feed(Data("data: line1\nda".utf8))
        frames += decoder.feed(Data("ta: line2\n\n".utf8))
        #expect(frames == [SSEFrame(data: "line1\nline2")])
    }

    @Test func severalFramesInOneFeed() {
        let decoder = SSEDecoder()
        let blob = """
        data: {"type":"RUN_STARTED","threadId":"t","runId":"r"}

        data: {"type":"RUN_FINISHED","threadId":"t","runId":"r"}


        """
        let frames = decoder.feed(Data(blob.utf8))
        #expect(frames.count == 2)
        #expect(frames[0].data.contains("RUN_STARTED"))
        #expect(frames[1].data.contains("RUN_FINISHED"))
    }

    @Test func finishFlushesPendingFrame() {
        let decoder = SSEDecoder()
        let mid = decoder.feed(Data("data: half\n".utf8))
        #expect(mid.isEmpty)
        let final = decoder.finish()
        #expect(final == [SSEFrame(data: "half")])
    }
}
