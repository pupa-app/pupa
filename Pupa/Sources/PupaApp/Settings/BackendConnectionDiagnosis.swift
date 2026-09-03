import Foundation
import OSLog

/// Where the backend lives, inferred from its hostname. Decides which fix to
/// name when a connection fails: a `.ts.net` host that won't resolve is almost
/// always a VPN that isn't up, while `localhost` refusing a socket is a backend
/// that isn't running.
enum BackendHostKind: Equatable {
    case loopback
    /// Tailscale: a MagicDNS `*.ts.net` name or a 100.64.0.0/10 CGNAT address.
    case tailnet
    /// RFC1918 / `.local` / a bare single-label name — LAN or some other VPN.
    case privateNetwork
    case publicInternet

    static func of(_ host: String?) -> BackendHostKind {
        guard let host = host?.lowercased(), !host.isEmpty else { return .publicInternet }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return .loopback }
        if host.hasSuffix(".ts.net") { return .tailnet }
        if let octets = ipv4Octets(host) {
            // 100.64.0.0/10 — the CGNAT range Tailscale hands out.
            if octets[0] == 100, (64...127).contains(octets[1]) { return .tailnet }
            if octets[0] == 10 { return .privateNetwork }
            if octets[0] == 172, (16...31).contains(octets[1]) { return .privateNetwork }
            if octets[0] == 192, octets[1] == 168 { return .privateNetwork }
            if octets[0] == 127 { return .loopback }
            return .publicInternet
        }
        if host.hasSuffix(".local") { return .privateNetwork }
        // A bare name with no dots only resolves through a search domain —
        // MagicDNS, mDNS, or a LAN resolver. Not the public internet.
        if !host.contains(".") { return .privateNetwork }
        return .publicInternet
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}

/// What went wrong reaching the backend, and whether it is worth waiting out.
///
/// Built from the raw `URLError` **plus** the backend host, so the message can
/// name the real failure and its likeliest fix rather than one generic
/// "couldn't connect". A tailnet host that fails DNS is the common case on this
/// project: the VPN is down, and nothing in the UI used to say so.
///
/// The raw error is logged, never shown. Filter Console.app by subsystem
/// `com.pupa-app.client`, category `backend`.
struct BackendConnectionDiagnosis: Equatable {
    enum Cause: Equatable {
        /// The socket died under a live connection — app backgrounded, blip.
        /// The only cause worth hiding behind a calm "Reconnecting…".
        case dropped
        case offline
        case hostNotFound
        case refused
        case timedOut
        case tls
        case unknown
    }

    let cause: Cause
    /// Short, user-facing, names the host and the likeliest fix. Never a dump.
    let message: String

    /// True only for a drop expected to heal by itself. Everything else needs
    /// the user to change something, so it must be said out loud.
    var isTransient: Bool { cause == .dropped }

    private static let log = Logger(subsystem: "com.pupa-app.client", category: "backend")

    static func diagnose(_ error: Error, host: String? = nil) -> BackendConnectionDiagnosis {
        log.error("backend error host=\(host ?? "-", privacy: .private) \(String(describing: error), privacy: .public)")
        guard let urlError = error as? URLError else {
            return .init(cause: .unknown, message: genericMessage)
        }
        let kind = BackendHostKind.of(host)
        let where_ = host.map { "“\($0)”" } ?? "the backend"

        switch urlError.code {
        case .networkConnectionLost, .cancelled:
            return .init(cause: .dropped, message: "The connection dropped.")

        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .init(cause: .offline, message: "This device is offline. Check your network and try again.")

        case .cannotFindHost, .dnsLookupFailed:
            switch kind {
            case .tailnet:
                return .init(
                    cause: .hostNotFound,
                    message: "Can’t find \(where_) — your Tailscale VPN looks disconnected. Turn it on, then Continue."
                )
            case .privateNetwork:
                return .init(
                    cause: .hostNotFound,
                    message: "Can’t find \(where_) — it’s a private name, so you may need the VPN on or the right network."
                )
            case .loopback, .publicInternet:
                return .init(
                    cause: .hostNotFound,
                    message: "Can’t find \(where_). Check the backend URL in Settings."
                )
            }

        case .cannotConnectToHost:
            switch kind {
            case .loopback:
                return .init(cause: .refused, message: "Nothing is listening on \(where_). Start the backend and Continue.")
            case .tailnet:
                return .init(
                    cause: .refused,
                    message: "\(where_) refused the connection — check Tailscale is connected and the backend is running."
                )
            case .privateNetwork, .publicInternet:
                return .init(cause: .refused, message: "\(where_) refused the connection. Check the backend is running.")
            }

        case .timedOut:
            switch kind {
            case .tailnet:
                return .init(
                    cause: .timedOut,
                    message: "\(where_) didn’t respond — check Tailscale is connected and the backend is up."
                )
            case .loopback, .privateNetwork, .publicInternet:
                return .init(cause: .timedOut, message: "\(where_) didn’t respond in time. Check it’s running.")
            }

        case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .init(cause: .tls, message: "\(where_) refused a secure connection. Check its URL and certificate.")

        default:
            return .init(cause: .unknown, message: "Can’t reach \(where_). Check it’s running and the URL is correct.")
        }
    }

    static let genericMessage = "Something went wrong talking to the backend. Please try again."
}
