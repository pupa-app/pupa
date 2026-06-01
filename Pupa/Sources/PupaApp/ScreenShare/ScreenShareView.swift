import SwiftUI
@preconcurrency import WebRTC

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct ScreenShareView: View {
    @Bindable var viewModel: ScreenShareViewModel
    @State private var shareIDInput: String = ""
    @State private var isFullscreen = false
    @Environment(\.scenePhase) private var scenePhase

    public init(viewModel: ScreenShareViewModel) {
        self.viewModel = viewModel
        self._shareIDInput = State(initialValue: viewModel.lastShareID ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            videoSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.restartIceIfConnected()
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isFullscreen) {
            if let track = viewModel.remoteVideoTrack {
                FullscreenVideoView(track: track, isRepicking: viewModel.isRepicking, isPresented: $isFullscreen) {
                    viewModel.requestRepick()
                }
            }
        }
        #endif
    }

    // MARK: - Controls bar

    private var controls: some View {
        HStack(spacing: 8) {
            TextField("Share ID (optional — leave blank to auto-join)", text: $shareIDInput)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                #if os(iOS)
                .autocapitalization(.none)
                #endif

            switch viewModel.status {
            case .disconnected, .failed:
                Button("Connect") {
                    let trimmed = shareIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.connect(shareID: trimmed.isEmpty ? nil : trimmed)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)

            default:
                if case .connected = viewModel.status {
                    Button("Change screen") {
                        viewModel.requestRepick()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRepicking)
                }
                if viewModel.remoteVideoTrack != nil {
                    fullscreenButton
                }
                Button("Disconnect") {
                    viewModel.disconnect()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Video surface

    @ViewBuilder
    private var videoSurface: some View {
        ZStack {
            Color.black

            if let track = viewModel.remoteVideoTrack {
                RTCVideoSurface(track: track)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isRepicking {
                    repickingOverlay
                }
            } else {
                statusOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
    }

    private var repickingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 6) {
                ProgressView()
                    .tint(.white)
                Text("Waiting for publisher to pick a new source…")
                    .foregroundStyle(.white)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var statusOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(statusText)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var fullscreenButton: some View {
        #if os(iOS)
        Button {
            isFullscreen = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.bordered)
        #else
        Button {
            NSApp.mainWindow?.toggleFullScreen(nil)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.bordered)
        #endif
    }

    // MARK: - Status helpers

    private var statusIcon: String {
        switch viewModel.status {
        case .disconnected: "rectangle.dashed"
        case .connecting, .waitingForPublisher: "wifi"
        case .connected: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        switch viewModel.status {
        case .disconnected:
            return "Tap Connect to auto-join the active publisher, or enter a Share ID to connect to a specific session."
        case .connecting:
            return "Connecting to broker…"
        case .waitingForPublisher:
            return "Waiting for the publisher to send the offer…"
        case .connected:
            return "Connected — track will appear shortly."
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}

// MARK: - RTC video surface (platform-specific renderer)

#if os(macOS)
private struct RTCVideoSurface: NSViewRepresentable {
    let track: RTCVideoTrack

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero)
        track.add(view)
        context.coordinator.attachedTrack = track
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
        if context.coordinator.attachedTrack !== track {
            context.coordinator.attachedTrack?.remove(nsView)
            track.add(nsView)
            context.coordinator.attachedTrack = track
        }
    }

    static func dismantleNSView(_ nsView: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(nsView)
        coordinator.attachedTrack = nil
        coordinator.view = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attachedTrack: RTCVideoTrack?
        weak var view: RTCMTLNSVideoView?
    }
}
#else
private struct RTCVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFit
        track.add(view)
        context.coordinator.attachedTrack = track
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if context.coordinator.attachedTrack !== track {
            context.coordinator.attachedTrack?.remove(uiView)
            track.add(uiView)
            context.coordinator.attachedTrack = track
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(uiView)
        coordinator.attachedTrack = nil
        coordinator.view = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attachedTrack: RTCVideoTrack?
        weak var view: RTCMTLVideoView?
    }
}

// MARK: - Fullscreen overlay (iOS only)

private struct FullscreenVideoView: View {
    let track: RTCVideoTrack
    let isRepicking: Bool
    @Binding var isPresented: Bool
    let onRepick: () -> Void

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            RTCVideoSurface(track: track)
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if isRepicking {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Waiting for publisher to pick a new source…")
                        .foregroundStyle(.white)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if showControls {
                HStack(spacing: 12) {
                    Button {
                        onRepick()
                    } label: {
                        Label("Change screen", systemImage: "rectangle.2.swap")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRepicking)

                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .background(Color.black.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 56)
                .padding(.trailing, 20)
                .transition(.opacity)
            }
        }
        .onAppear { scheduleHide() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }
}
#endif
