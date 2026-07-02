import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AgentClientError: Error, Sendable, CustomStringConvertible {
    case httpStatus(Int, body: String?)
    case malformedEvent(String, underlying: Error)
    case requestFailed(Error)
    case cancelled

    public var description: String {
        switch self {
        case .httpStatus(let code, _):
            return "backend returned HTTP \(code)"
        case .requestFailed(let err):
            return "couldn't reach the backend: \(err.localizedDescription)"
        case .malformedEvent:
            return "unexpected response from the backend"
        case .cancelled:
            return "cancelled"
        }
    }
}

/// An `AgentEvent` plus the replay sequence number the backend's resumable-SSE
/// layer stamped on its frame (the SSE `id:` field). `seq` is nil when the
/// backend predates the replay middleware or the frame carried no id.
/// Consumers track the highest seen `seq` so a dropped socket can re-attach
/// with `forwardedProps.command.reattach.after_seq` and replay only what was
/// missed. See pupa#103 / pupa-backend#40.
public struct SequencedAgentEvent: Sendable {
    public let event: AgentEvent
    public let seq: Int?

    public init(event: AgentEvent, seq: Int?) {
        self.event = event
        self.seq = seq
    }
}

/// Low-level AG-UI client. Posts a `RunAgentInput` to the configured endpoint
/// and yields decoded `AgentEvent`s as they arrive.
///
/// Performs **one round** only — the multi-round loop (executing frontend
/// tools, posting follow-ups) lives in `AgentSession`.
public struct AgentClient: Sendable {
    public let endpoint: URL
    public let session: URLSession
    public let extraHeaders: [String: String]

    public init(
        endpoint: URL,
        session: URLSession = .shared,
        extraHeaders: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.session = session
        self.extraHeaders = extraHeaders
    }

    /// Run one agent round. The returned stream yields events until the
    /// server emits `RUN_FINISHED` (or an error) and the connection closes.
    ///
    /// Convenience wrapper over `runSequenced(_:)` for callers that don't
    /// care about replay sequence numbers.
    public func run(_ input: RunAgentInput) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await sequenced in runSequenced(input) {
                        continuation.yield(sequenced.event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Run one agent round, yielding each event together with the replay
    /// `seq` parsed from its SSE `id:` field (nil when absent).
    ///
    /// A `204 No Content` finishes immediately with no events: the backend's
    /// replay layer answers re-attach requests for unknown/evicted threads
    /// that way, and "nothing to replay" is a clean outcome, not an error.
    public func runSequenced(_ input: RunAgentInput) -> AsyncThrowingStream<SequencedAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = []
                    req.httpBody = try encoder.encode(input)
                    AGUIKitLog.client(
                        "POST \(endpoint) " +
                        "threadId=\(input.threadId) runId=\(input.runId) " +
                        "msgs=\(input.messages.count) tools=\(input.tools.count) " +
                        "body=\(req.httpBody?.count ?? 0)B"
                    )

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: req)
                    } catch {
                        if Task.isCancelled {
                            continuation.finish(throwing: AgentClientError.cancelled)
                        } else {
                            continuation.finish(throwing: AgentClientError.requestFailed(error))
                        }
                        return
                    }

                    if let http = response as? HTTPURLResponse, http.statusCode == 204 {
                        // Replay re-attach against an unknown/evicted thread:
                        // nothing buffered to send. Clean empty round.
                        AGUIKitLog.client("204 no content (no replay available)")
                        continuation.finish()
                        return
                    }

                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        // Drain the body for diagnostic context.
                        var bodyBytes = Data()
                        for try await byte in bytes {
                            bodyBytes.append(byte)
                            if bodyBytes.count > 8 * 1024 { break }
                        }
                        let body = String(data: bodyBytes, encoding: .utf8)
                        continuation.finish(throwing: AgentClientError.httpStatus(http.statusCode, body: body))
                        return
                    }

                    let decoder = SSEDecoder()
                    let jsonDecoder = JSONDecoder()
                    var chunk = Data()
                    chunk.reserveCapacity(4096)

                    func yieldFrame(_ frame: SSEFrame) throws {
                        guard !frame.data.isEmpty else { return }
                        guard let data = frame.data.data(using: .utf8) else { return }
                        do {
                            let event = try jsonDecoder.decode(AgentEvent.self, from: data)
                            AGUIKitLog.client("evt \(AGUIKitLog.shortLabel(event))")
                            continuation.yield(SequencedAgentEvent(event: event, seq: frame.id.flatMap(Int.init)))
                        } catch {
                            throw AgentClientError.malformedEvent(frame.data, underlying: error)
                        }
                    }

                    for try await byte in bytes {
                        if Task.isCancelled {
                            continuation.finish(throwing: AgentClientError.cancelled)
                            return
                        }
                        chunk.append(byte)
                        // Flush in modest batches to avoid one-byte-at-a-time decoder calls.
                        if chunk.count >= 1024 || byte == 0x0A {
                            let frames = decoder.feed(chunk)
                            chunk.removeAll(keepingCapacity: true)
                            for frame in frames {
                                try yieldFrame(frame)
                            }
                        }
                    }
                    // Final flush.
                    var finalFrames = decoder.feed(chunk)
                    finalFrames.append(contentsOf: decoder.finish())
                    for frame in finalFrames {
                        try yieldFrame(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
