import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLProtocol stub that lets a test return a canned (status, body) per request.
///
/// Configured via `MockURLProtocol.responder` — set this before kicking off
/// requests, then read `MockURLProtocol.requestCount` to assert call count.
/// Always reset state in test setup. Tests that share a process must be
/// serialised — register the suite with `.serialized`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var requestCount: Int = 0
    nonisolated(unsafe) static var lastRequestBody: Data?
    /// One entry per `startLoading` call, in chronological order. Tests that
    /// span multiple rounds (e.g. mid-turn `toolFilter` refresh) read this
    /// to inspect each round's `RunAgentInput.tools` independently.
    nonisolated(unsafe) static var requestBodies: [Data] = []

    static func reset() {
        responder = nil
        requestCount = 0
        lastRequestBody = nil
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
        // URLProtocol bodies aren't visible via httpBody when streamed; capture
        // via httpBodyStream if present, else fall back to httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            MockURLProtocol.lastRequestBody = data
            MockURLProtocol.requestBodies.append(data)
        } else {
            MockURLProtocol.lastRequestBody = request.httpBody
            MockURLProtocol.requestBodies.append(request.httpBody ?? Data())
        }

        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body, headers) = responder(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://mock/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Build a URLSession that routes through `MockURLProtocol`.
func makeMockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    cfg.timeoutIntervalForRequest = 5
    cfg.timeoutIntervalForResource = 5
    return URLSession(configuration: cfg)
}

/// Encode a list of JSON event strings as an SSE body (`data: …\n\n`).
func sseBody(_ events: [String]) -> Data {
    let payload = events.map { "data: \($0)\n\n" }.joined()
    return Data(payload.utf8)
}
