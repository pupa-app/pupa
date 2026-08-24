import CryptoKit
import Foundation
import PupaScripting

/// URLSessionDelegate that accepts a server certificate whose SHA-256
/// fingerprint matches a known value — used for self-signed HTTPS backends
/// set up with `make setup` (the fingerprint is embedded in the pairing QR).
///
/// Only activates when `fingerprint` is non-nil; all other challenge types
/// fall through to the default (system trust) handling.
final class CertPinningDelegate: NSObject, URLSessionDelegate, Sendable {
    private let fingerprint: String  // lowercase hex SHA-256 of the DER cert

    init(fingerprint: String) {
        self.fingerprint = fingerprint.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = cert.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Compute SHA-256 of the DER-encoded leaf certificate.
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        if hex == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

extension URLSession {
    /// Returns a URLSession pinned to the given SHA-256 cert fingerprint, or
    /// `.shared` when no fingerprint is configured.
    ///
    /// An app launched with `-PupaScript` gets a session that answers from the
    /// script instead — the one place the whole app's backend traffic can be
    /// intercepted, so a UI test never needs a live backend.
    static func forBackend(certFingerprint: String?) -> URLSession {
        if LaunchOptions.isScripted { return ScriptedTransport.session() }
        guard let fp = certFingerprint, !fp.isEmpty else { return .shared }
        let delegate = CertPinningDelegate(fingerprint: fp)
        return URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
    }
}
