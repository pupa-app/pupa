#if os(iOS)
// AVFoundation hasn't fully audited its Sendable conformances yet —
// importing @preconcurrency lowers those checks to warnings for types
// we don't control (AVMetadataObject, AVCaptureSession, etc.) while
// keeping strict checking on our own code.
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Result of scanning a Pupa pairing QR code.
struct PairingQRResult {
    /// The 8-char pairing code (always present).
    let code: String
    /// Backend URL parsed from `pupa-pair://?url=…` QR codes.
    /// Nil for bare-code QRs (backward compat).
    let backendURL: URL?
    /// SHA-256 fingerprint of the backend's TLS certificate (hex).
    /// Present only when the backend was set up with `make setup` and HTTPS.
    let certFingerprint: String?
}

/// Camera-backed QR scanner used by the Pair-via-QR flow. Reads the first
/// QR payload it sees and hands it back via the `onScan` closure; the caller
/// dismisses the sheet and decides whether the payload is a pairing code.
///
/// Accepts both:
/// - A bare 8-char alphanumeric code matching the pairing alphabet.
/// - A URL like `pupa-pair://?url=https://…&code=ABCDEFGH&fp=<sha256>`
///   (emitted by `make pair` when setup extras are installed).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    /// Extract a `PairingQRResult` from raw scanned content.
    /// Returns nil when the payload is not a recognisable pairing QR.
    static func extractPairingResult(from scanned: String) -> PairingQRResult? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("pupa-pair://"),
           let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty
        {
            let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value
            let backendURL = urlString.flatMap { URL(string: $0) }
            let fp = components.queryItems?.first(where: { $0.name == "fp" })?.value
            return PairingQRResult(code: code.uppercased(), backendURL: backendURL, certFingerprint: fp)
        }
        // Bare code fallback: 8 chars from the pairing alphabet.
        let candidate = trimmed.uppercased()
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        if candidate.count == 8,
           candidate.unicodeScalars.allSatisfy({ alphabet.contains($0) }) {
            return PairingQRResult(code: candidate, backendURL: nil, certFingerprint: nil)
        }
        return nil
    }

    /// Legacy helper retained for backward-compat with existing call-sites
    /// that only need the code string.
    static func extractPairingCode(from scanned: String) -> String? {
        extractPairingResult(from: scanned)?.code
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
        addCancelButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showError("Camera unavailable. Use the Pairing code field below to paste the code instead.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showError("Couldn't initialise the QR reader.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private func addCancelButton() {
        let button = UIButton(type: .system)
        button.setTitle("Cancel", for: .normal)
        button.tintColor = .white
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
        ])
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc private func cancelTapped() {
        onScan?("")
    }

    // Protocol requirement is nonisolated; the class is implicitly @MainActor
    // (UIViewController subclass), so satisfying it requires the method itself
    // to be nonisolated. Safe because `setMetadataObjectsDelegate` was given
    // `queue: .main` — every callback already arrives on the main actor.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Pull the Sendable payload out of the non-Sendable
        // [AVMetadataObject] before crossing into the MainActor closure —
        // otherwise Swift 6 strict concurrency complains about capturing the
        // array, even though `assumeIsolated` doesn't actually hop threads.
        guard let qr = metadataObjects.first(where: { $0.type == .qr }) as? AVMetadataMachineReadableCodeObject,
              let payload = qr.stringValue
        else { return }
        MainActor.assumeIsolated {
            guard !hasReported else { return }
            hasReported = true
            AudioServicesPlaySystemSound(1057)  // Tink — short success sound.
            onScan?(payload)
        }
    }
}
#endif
