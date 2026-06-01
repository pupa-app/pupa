import Foundation
import Observation
@preconcurrency import WebRTC

// WebRTC ObjC types aren't marked Sendable, but in our use they're produced
// on a worker thread and handed to MainActor exactly once. Retroactive
// `@unchecked Sendable` keeps Swift 6 strict concurrency happy — same
// pattern the sidecar uses for `SCContentFilter`.
extension RTCSessionDescription: @retroactive @unchecked Sendable {}
extension RTCIceCandidate: @retroactive @unchecked Sendable {}
extension RTCMediaStreamTrack: @retroactive @unchecked Sendable {}

/// Lifecycle state surfaced to the SwiftUI panel. Drives status chips +
/// determines whether the connect button or video surface is visible.
public enum ScreenShareConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case waitingForPublisher  // viewer's WS open but publisher hasn't sent the offer
    case connected
    case failed(String)
}

/// Owns the viewer's RTCPeerConnection + signaling. Mirrors the
/// `ChatSessionCoordinator` shape (`@MainActor`, `@Observable`) so SwiftUI
/// reacts to status changes. Exposed surface is intentionally tiny —
/// `connect(shareID:)` + `disconnect()` + `status` + `remoteVideoTrack`.
/// `shareID` is optional — nil auto-discovers the sole active publisher.
///
/// The track is exposed (not the stream) because `RTCMTLNSVideoView` /
/// `RTCMTLVideoView` add themselves as renderers directly on a track. We
/// publish the track as `@Observable` state so the platform-specific video
/// view in `ScreenShareView.swift` can swap renderers when it changes.
@MainActor
@Observable
public final class ScreenShareViewModel {
    public private(set) var status: ScreenShareConnectionStatus = .disconnected
    public private(set) var remoteVideoTrack: RTCVideoTrack?
    public private(set) var lastShareID: String?
    /// True while the viewer has requested a re-pick and is waiting for the
    /// publisher to select a new source. Cleared when the first new frame
    /// arrives or the connection drops.
    public private(set) var isRepicking: Bool = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let factory: RTCPeerConnectionFactory
    @ObservationIgnored private var peerConnection: RTCPeerConnection?
    @ObservationIgnored private var signaling: ScreenShareSignalingClient?
    @ObservationIgnored private var pendingRemoteCandidates: [ScreenShareCandidatePayload] = []
    @ObservationIgnored private var remoteDescriptionSet = false
    @ObservationIgnored private var delegateBridge: PeerConnectionDelegateBridge?
    /// Sticky reason captured from a broker `error` message. The WS close that
    /// follows it would otherwise overwrite the message with the useless
    /// "signalling closed (code 1006)" string.
    @ObservationIgnored private var pendingErrorReason: String?
    /// Clears `isRepicking` on the first new frame after a repick request.
    /// `handleRemoteTrack` only fires for *new* tracks; the publisher reuses
    /// the same track on repick, so we need a separate frame detector.
    @ObservationIgnored private var repickDetector: RepickFrameDetector?

    public init(settings: SettingsStore) {
        self.settings = settings
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }

    deinit {
        peerConnection?.close()
        RTCCleanupSSL()
    }

    public func connect(shareID: String?) {
        disconnect()  // clean slate
        if let shareID, !shareID.isEmpty { lastShareID = shareID }
        status = .connecting

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let bridge = PeerConnectionDelegateBridge()
        bridge.viewModel = self
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: bridge) else {
            status = .failed("RTCPeerConnectionFactory returned nil")
            return
        }
        self.delegateBridge = bridge
        self.peerConnection = pc

        let signaling = ScreenShareSignalingClient()
        signaling.delegate = self
        self.signaling = signaling
        // Extract the bearer value out of the resolved authHeaders — that's
        // now sourced from the Keychain (paired-device token) rather than the
        // pre-#163 static api-key field.
        let bearer = settings.authHeaders["Authorization"]?
            .split(separator: " ", maxSplits: 1)
            .last
            .map(String.init)
        signaling.connect(brokerBase: settings.backendURL, shareID: shareID, bearerToken: bearer)
        status = .waitingForPublisher
    }

    /// Ask the publisher to re-open the source picker so the user can share a
    /// different window or application without disconnecting.
    public func requestRepick() {
        signaling?.send(.repick)
        isRepicking = true
        // Publisher reuses the same RTCVideoTrack on repick, so `handleRemoteTrack`
        // (which only fires for new tracks) won't clear isRepicking. Attach a
        // one-shot frame detector that fires on the first frame from the new source.
        if let track = remoteVideoTrack {
            let detector = RepickFrameDetector { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRepicking = false
                    if let t = self.remoteVideoTrack, let d = self.repickDetector {
                        t.remove(d)
                    }
                    self.repickDetector = nil
                }
            }
            repickDetector = detector
            track.add(detector)
        }
    }

    public func disconnect() {
        signaling?.send(.bye)
        signaling?.close()
        signaling = nil
        if let track = remoteVideoTrack, let detector = repickDetector {
            track.remove(detector)
        }
        repickDetector = nil
        peerConnection?.close()
        peerConnection = nil
        delegateBridge = nil
        remoteVideoTrack = nil
        remoteDescriptionSet = false
        pendingRemoteCandidates.removeAll()
        pendingErrorReason = nil
        isRepicking = false
        status = .disconnected
    }

    /// Trigger an ICE restart on the active peer connection. Called when the
    /// iOS app returns from background — WebRTC sessions get suspended while
    /// backgrounded and the stream stays frozen on resume without this kick.
    /// Safe to call when there's no active connection (no-op).
    public func restartIceIfConnected() {
        guard let pc = peerConnection else { return }
        guard case .connected = status else { return }
        pc.restartIce()
    }

    fileprivate func handleRemoteTrack(_ track: RTCMediaStreamTrack) {
        guard let videoTrack = track as? RTCVideoTrack else { return }
        remoteVideoTrack = videoTrack
        isRepicking = false
    }

    fileprivate func handleLocalCandidate(_ candidate: RTCIceCandidate) {
        let payload = ScreenShareCandidatePayload(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        signaling?.send(.ice(payload))
    }

    fileprivate func handleConnectionStateChange(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected: status = .connected
        case .connecting: status = .connecting
        case .disconnected: status = .waitingForPublisher
        case .failed: status = .failed("ICE failed — check broker reachability and network")
        case .closed: status = .disconnected
        case .new: break
        @unknown default: break
        }
    }

    private func handleOffer(sdp: String) {
        guard let pc = peerConnection else { return }
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.status = .failed("setRemoteDescription failed: \(error.localizedDescription)")
                    return
                }
                self.flushPendingRemoteCandidates()
                self.createAndSendAnswer()
            }
        }
    }

    private func createAndSendAnswer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.answer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.status = .failed("createAnswer failed: \(error.localizedDescription)")
                    return
                }
                guard let sdp else { return }
                pc.setLocalDescription(sdp) { [weak self] error in
                    guard let self else { return }
                    Task { @MainActor in
                        if let error {
                            self.status = .failed("setLocalDescription failed: \(error.localizedDescription)")
                            return
                        }
                        self.signaling?.send(.answer(sdp: sdp.sdp))
                    }
                }
            }
        }
    }

    private func addRemoteCandidate(_ payload: ScreenShareCandidatePayload) {
        if !remoteDescriptionSet {
            pendingRemoteCandidates.append(payload)
            return
        }
        applyRemoteCandidate(payload)
    }

    private func flushPendingRemoteCandidates() {
        remoteDescriptionSet = true
        let queued = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        for c in queued { applyRemoteCandidate(c) }
    }

    private func applyRemoteCandidate(_ payload: ScreenShareCandidatePayload) {
        guard let pc = peerConnection else { return }
        let candidate = RTCIceCandidate(
            sdp: payload.candidate,
            sdpMLineIndex: payload.sdpMLineIndex,
            sdpMid: payload.sdpMid
        )
        pc.add(candidate) { _ in }
    }
}

extension ScreenShareViewModel: ScreenShareSignalingClientDelegate {
    nonisolated func signalingClient(_ client: ScreenShareSignalingClient, didReceive message: ScreenShareSignalingMessage) {
        Task { @MainActor in
            switch message {
            case .offer(let sdp):
                self.handleOffer(sdp: sdp)
            case .ice(let payload):
                self.addRemoteCandidate(payload)
            case .bye:
                self.status = .waitingForPublisher
                self.remoteVideoTrack = nil
            case .error(_, let reason):
                // Stash the reason so the WS close that immediately follows
                // doesn't overwrite it with the useless 1006-disguised code.
                self.pendingErrorReason = reason
                self.status = .failed(reason)
            case .answer, .viewerJoined, .repick, .unknown:
                break  // viewer doesn't expect these
            }
        }
    }

    nonisolated func signalingClient(_ client: ScreenShareSignalingClient, didCloseWithCode code: URLSessionWebSocketTask.CloseCode) {
        Task { @MainActor in
            // If the broker just told us why with an `error` message, keep
            // that reason. Otherwise fall back to a generic close diagnostic.
            if let reason = self.pendingErrorReason {
                self.status = .failed(reason)
                return
            }
            switch self.status {
            case .connected, .waitingForPublisher, .connecting:
                self.status = .failed("connection lost (close code \(code.rawValue)) — check the backend URL and that the publisher is still running")
            default:
                break
            }
        }
    }
}

/// One-shot RTCVideoRenderer that fires `onFirstFrame` the first time a
/// rendered frame arrives and then becomes a no-op. Used to clear `isRepicking`
/// immediately when new video flows from the re-picked source, without waiting
/// for a full track re-negotiation (`handleRemoteTrack` only fires on new tracks).
private final class RepickFrameDetector: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    let onFirstFrame: @Sendable () -> Void

    init(onFirstFrame: @escaping @Sendable () -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.withLock {
            guard !fired else { return }
            fired = true
        }
        onFirstFrame()
    }
}

/// RTCPeerConnectionDelegate is `@objc` so it can't be conformed by an
/// `@MainActor` class without elaborate isolation gymnastics. This bridge
/// receives the WebRTC callbacks off the main thread and hops them to the
/// view model.
private final class PeerConnectionDelegateBridge: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    weak var viewModel: ScreenShareViewModel?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.viewModel?.handleLocalCandidate(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            self?.viewModel?.handleConnectionStateChange(newState)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        Task { @MainActor [weak self] in
            if let track {
                self?.viewModel?.handleRemoteTrack(track)
            }
        }
    }
}
