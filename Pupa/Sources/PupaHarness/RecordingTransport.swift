import Foundation
import AGUIKit
import PupaScripting

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pass-through transport that tees a live backend's SSE into a `Script`.
///
/// The turn runs for real — bytes are forwarded as they arrive, so parking,
/// keepalives and timing behave exactly as they do without it. On completion
/// each round's frames are decoded into `rounds`, which serializes to the same
/// `.jsonl` `ScriptedTransport` replays. That is the whole point: fixtures are
/// recorded from the real backend rather than guessed, so they stay honest as
/// it evolves.
public final class RecordingTransport: URLProtocol, @unchecked Sendable {
    /// One round per POST, in order — write with `Script(rounds:).jsonl()`.
    nonisolated(unsafe) public static var rounds: [ScriptedRound] = []
    nonisolated(unsafe) public static var postBodies: [Data] = []

    public static func reset() {
        rounds = []
        postBodies = []
    }

    /// A session that records. Long timeouts: a real turn parked on a frontend
    /// tool legitimately holds the socket open for minutes.
    public static func session(timeout: TimeInterval = 600) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingTransport.self]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        return URLSession(configuration: cfg)
    }

    private var upstreamTask: URLSessionDataTask?
    private var upstream: URLSession?
    private var buffer = Data()
    private var isPost = false

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        isPost = request.httpMethod == "POST"
        var forwarded = request
        if isPost {
            // The body stream is single-shot and we just consumed it, so hand
            // the upstream request the bytes instead.
            let body = Self.readBody(request)
            Self.postBodies.append(body)
            forwarded.httpBodyStream = nil
            forwarded.httpBody = body
        }
        // The upstream session must NOT carry this protocol class, or the
        // request loops back into here forever.
        let session = URLSession(
            configuration: .ephemeral, delegate: Proxy(owner: self), delegateQueue: nil)
        upstream = session
        upstreamTask = session.dataTask(with: forwarded)
        upstreamTask?.resume()
    }

    public override func stopLoading() {
        upstreamTask?.cancel()
        upstream?.invalidateAndCancel()
    }

    // MARK: Teeing

    fileprivate func received(_ response: URLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    fileprivate func received(_ data: Data) {
        if isPost { buffer.append(data) }
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func finished(_ error: (any Error)?) {
        if isPost { Self.rounds.append(Self.round(from: buffer, status: statusCode)) }
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        upstream?.finishTasksAndInvalidate()
    }

    private var statusCode: Int {
        (upstreamTask?.response as? HTTPURLResponse)?.statusCode ?? 200
    }

    /// Decode a round's raw SSE bytes into scriptable events.
    public static func round(from body: Data, status: Int) -> ScriptedRound {
        let frames = SSEDecoder().feed(body)
        let decoder = JSONDecoder()
        let events = frames.compactMap { frame in
            try? decoder.decode(AnyJSON.self, from: Data(frame.data.utf8))
        }
        return ScriptedRound(status: status == 200 ? nil : status, events: events)
    }

    private static func readBody(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { chunk.deallocate(); stream.close() }
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(chunk, maxLength: 4096)
            if read <= 0 { break }
            data.append(chunk, count: read)
        }
        return data
    }

    /// Forwards the upstream task's callbacks back into the `URLProtocol`.
    private final class Proxy: NSObject, URLSessionDataDelegate {
        private let owner: RecordingTransport
        init(owner: RecordingTransport) { self.owner = owner }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            owner.received(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner.received(data)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            owner.finished(error)
        }
    }
}
