import Foundation
import AGUIKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One backend round: what a single `POST` to the agent endpoint answers with.
///
/// `round` is 1-based and optional — omit it and rounds are served in file
/// order. `events` are raw AG-UI event objects; they are re-emitted as SSE
/// frames with sequential `id:` lines, the field the resumable-replay backend
/// uses to carry the per-event sequence number.
public struct ScriptedRound: Codable, Sendable {
    /// How a round fails instead of completing.
    public enum Failure: String, Codable, Sendable {
        /// Refuse at connect time — a socket that never opened.
        case connect
        /// Deliver `events` up to `failAfter`, then kill the connection.
        case midStream
    }

    public var round: Int?
    public var status: Int?
    public var fail: Failure?
    /// Events emitted before a `midStream` failure. Defaults to half of them.
    public var failAfter: Int?
    public var events: [AnyJSON]

    public init(
        round: Int? = nil,
        status: Int? = nil,
        fail: Failure? = nil,
        failAfter: Int? = nil,
        events: [AnyJSON]
    ) {
        self.round = round
        self.status = status
        self.fail = fail
        self.failAfter = failAfter
        self.events = events
    }
}

/// A whole scripted conversation: one `ScriptedRound` per line of a `.jsonl`.
public struct Script: Sendable {
    public var rounds: [ScriptedRound]

    public init(rounds: [ScriptedRound]) { self.rounds = rounds }

    /// Parse a `.jsonl` script. Blank lines and `//` comment lines are skipped
    /// so fixtures can be annotated.
    public static func load(_ url: URL) throws -> Script {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// One round per line is the canonical form (what `record` writes), but a
    /// round may also span several lines — hand-written fixtures are far more
    /// readable with one event per line. Lines accumulate until they parse.
    public static func parse(_ text: String) throws -> Script {
        let decoder = JSONDecoder()
        var rounds: [ScriptedRound] = []
        var buffer = ""
        var bufferStart = 0

        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if buffer.isEmpty, line.isEmpty || line.hasPrefix("//") { continue }
            if buffer.isEmpty { bufferStart = n + 1 }
            buffer += line
            guard let round = try? decoder.decode(ScriptedRound.self, from: Data(buffer.utf8))
            else { continue }
            rounds.append(round)
            buffer = ""
        }
        guard buffer.isEmpty else {
            // Report the real decode error against the whole unparsed round.
            do {
                rounds.append(try decoder.decode(ScriptedRound.self, from: Data(buffer.utf8)))
            } catch {
                throw ScriptError.badLine(number: bufferStart, underlying: error)
            }
            return Script(rounds: rounds)
        }
        return Script(rounds: rounds)
    }

    /// Serialize back to `.jsonl` — what `record` mode writes.
    public func jsonl() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let lines = try rounds.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ScriptError: Error, CustomStringConvertible {
    case badLine(number: Int, underlying: any Error)

    public var description: String {
        switch self {
        case .badLine(let n, let e): "script line \(n): \(e)"
        }
    }
}

/// `URLProtocol` that answers the agent endpoint from a `Script`, and records
/// every POST body so a caller can inspect the wire.
///
/// Generalizes the per-suite mocks (`RelaunchMockURLProtocol`, AGUIKit's
/// `MockURLProtocol`): one script format, shared by the headless scenarios,
/// `PupaCtl replay`, and the launched app under `-PupaScript`.
///
/// Statics are process-global — serialize anything that shares the process.
public final class ScriptedTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) public static var script: Script?
    /// One entry per POST, in order. Decode as `RunAgentInput` to read the
    /// messages and tool schemas each round actually carried.
    nonisolated(unsafe) public static var postBodies: [Data] = []
    /// Connect-time failure injector keyed by 1-based POST index. Takes
    /// precedence over the script's own `fail`.
    nonisolated(unsafe) public static var failer: (@Sendable (Int) -> URLError?)?
    /// Body served for non-POST requests (the transcript fetch).
    nonisolated(unsafe) public static var getBody: Data = Data("[]".utf8)

    nonisolated(unsafe) private static var nextSeq = 0

    public static func reset() {
        script = nil
        postBodies = []
        failer = nil
        getBody = Data("[]".utf8)
        nextSeq = 0
    }

    /// A `URLSession` wired to this transport. Short timeouts — a scripted
    /// round that hangs is a bug, not something to wait 60s on.
    public static func session(timeout: TimeInterval = 10) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ScriptedTransport.self]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        return URLSession(configuration: cfg)
    }

    /// The round answering the nth POST (1-based): an explicit `round` match
    /// first, else positional. `nil` past the end → 204.
    public static func round(for index: Int) -> ScriptedRound? {
        guard let script else { return nil }
        if let explicit = script.rounds.first(where: { $0.round == index }) { return explicit }
        let positional = script.rounds.filter { $0.round == nil }
        guard index - 1 < positional.count else { return nil }
        return positional[index - 1]
    }

    /// Encode events as an SSE body, stamping each frame with a running `id:`.
    public static func sseBody(_ events: [AnyJSON]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var out = ""
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            out += "id: \(nextSeq)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
            nextSeq += 1
        }
        return Data(out.utf8)
    }

    // MARK: URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard request.httpMethod == "POST" else { return serveGET() }

        Self.postBodies.append(Self.readBody(request))
        let index = Self.postBodies.count

        if let error = Self.failer?(index) {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let round = Self.round(for: index) else { return serve(status: 204, body: nil) }
        if round.fail == .connect {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        guard round.fail == .midStream else {
            return serve(status: round.status ?? 200, body: Self.sseBody(round.events))
        }
        let cut = round.failAfter ?? max(1, round.events.count / 2)
        serve(status: round.status ?? 200,
              body: Self.sseBody(Array(round.events.prefix(cut))),
              finish: false)
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }

    public override func stopLoading() {}

    // MARK: Helpers

    /// `URLProtocol` hides streamed bodies from `httpBody`, so drain the stream.
    private static func readBody(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate(); stream.close() }
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func serveGET() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.getBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func serve(status: Int, body: Data?, finish: Bool = true) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}
