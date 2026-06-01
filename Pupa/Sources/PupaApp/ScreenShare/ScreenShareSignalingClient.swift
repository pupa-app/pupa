import Foundation

protocol ScreenShareSignalingClientDelegate: AnyObject, Sendable {
    func signalingClient(_ client: ScreenShareSignalingClient, didReceive message: ScreenShareSignalingMessage)
    func signalingClient(_ client: ScreenShareSignalingClient, didCloseWithCode code: URLSessionWebSocketTask.CloseCode)
}

// Wire shape matches the broker's relay format. Mirrors the sidecar's
// SignalingMessage but with viewer semantics: we never *send* `viewer_joined`
// (the broker emits it to the publisher when we connect) and we never *send*
// `offer` (publishers offer, viewers answer).
enum ScreenShareSignalingMessage: Sendable {
    case viewerJoined
    case offer(sdp: String)
    case answer(sdp: String)
    case ice(ScreenShareCandidatePayload)
    case bye
    /// Pre-close JSON the broker sends before rejecting a connection. We
    /// rely on this instead of the WS close code because URLSessionWebSocketTask
    /// flattens all 4xxx codes to `.abnormalClosure` (1006) on iOS.
    case error(code: Int, reason: String)
    /// Viewer-initiated request asking the publisher to re-open the source
    /// picker so the user can switch to a different window or application
    /// without tearing down the WebRTC connection.
    case repick
    case unknown(String)

    init?(json: [String: Any]) {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "viewer_joined": self = .viewerJoined
        case "bye": self = .bye
        case "repick": self = .repick
        case "offer":
            guard let sdp = json["sdp"] as? String else { return nil }
            self = .offer(sdp: sdp)
        case "answer":
            guard let sdp = json["sdp"] as? String else { return nil }
            self = .answer(sdp: sdp)
        case "ice":
            guard let inner = json["candidate"] as? [String: Any],
                  let candidate = inner["candidate"] as? String
            else { return nil }
            let sdpMid = inner["sdpMid"] as? String
            let sdpMLineIndex: Int32
            if let i = inner["sdpMLineIndex"] as? Int {
                sdpMLineIndex = Int32(i)
            } else if let n = inner["sdpMLineIndex"] as? NSNumber {
                sdpMLineIndex = n.int32Value
            } else {
                sdpMLineIndex = 0
            }
            self = .ice(ScreenShareCandidatePayload(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex))
        case "error":
            let code = (json["code"] as? Int) ?? (json["code"] as? NSNumber)?.intValue ?? 0
            let reason = (json["reason"] as? String) ?? "unspecified error"
            self = .error(code: code, reason: reason)
        default:
            self = .unknown(type)
        }
    }

    var json: [String: Any] {
        switch self {
        case .viewerJoined: return ["type": "viewer_joined"]
        case .bye: return ["type": "bye"]
        case .offer(let sdp): return ["type": "offer", "sdp": sdp]
        case .answer(let sdp): return ["type": "answer", "sdp": sdp]
        case .ice(let payload):
            var inner: [String: Any] = [
                "candidate": payload.candidate,
                "sdpMLineIndex": payload.sdpMLineIndex,
            ]
            if let mid = payload.sdpMid { inner["sdpMid"] = mid }
            return ["type": "ice", "candidate": inner]
        case .error(let code, let reason):
            return ["type": "error", "code": code, "reason": reason]
        case .repick: return ["type": "repick"]
        case .unknown(let type): return ["type": type]
        }
    }
}

struct ScreenShareCandidatePayload: Sendable, Equatable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32
}

final class ScreenShareSignalingClient: NSObject, @unchecked Sendable {
    weak var delegate: (any ScreenShareSignalingClientDelegate)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let stateLock = NSLock()
    private var closed = false

    override init() {
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// `brokerBase` is the FastAPI base URL (e.g. `http://host:8004/`). We
    /// switch the scheme to `ws[s]` and append `/screenshare/ws` ourselves
    /// rather than asking the caller to pre-build it — the same setting drives
    /// chat (`AgentClient`) and screen-share, so they shouldn't diverge.
    /// `shareID` is optional — nil or empty omits the query param and lets the
    /// broker auto-discover the sole active publisher.
    /// `bearerToken` is typically a paired-device token from the Keychain
    /// (extracted by `SettingsStore.authHeaders`); pass `nil` for unauth
    /// backends.
    func connect(brokerBase: URL, shareID: String?, bearerToken: String?) {
        guard var components = URLComponents(url: brokerBase, resolvingAgainstBaseURL: false) else {
            return
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http", nil: components.scheme = "ws"
        default: break
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/screenshare/ws"
        var queryItems = [URLQueryItem(name: "role", value: "viewer")]
        if let shareID, !shareID.isEmpty {
            queryItems.append(URLQueryItem(name: "share_id", value: shareID))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        stateLock.withLock { self.task = task }
        task.resume()
        receiveLoop(task)
    }

    func send(_ message: ScreenShareSignalingMessage) {
        guard let task = stateLock.withLock({ self.task }) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: message.json),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    func close() {
        let task = stateLock.withLock { () -> URLSessionWebSocketTask? in
            guard !self.closed else { return nil }
            self.closed = true
            return self.task
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .failure:
                self.delegate?.signalingClient(self, didCloseWithCode: .abnormalClosure)
            case .success(let message):
                self.handleIncoming(message)
                if !self.stateLock.withLock({ self.closed }) {
                    self.receiveLoop(task)
                }
            }
        }
    }

    private func handleIncoming(_ wsMessage: URLSessionWebSocketTask.Message) {
        let payload: Data?
        switch wsMessage {
        case .string(let text): payload = text.data(using: .utf8)
        case .data(let data): payload = data
        @unknown default: payload = nil
        }
        guard let payload,
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let message = ScreenShareSignalingMessage(json: json)
        else { return }
        delegate?.signalingClient(self, didReceive: message)
    }
}

extension ScreenShareSignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {}
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        delegate?.signalingClient(self, didCloseWithCode: closeCode)
    }
}
