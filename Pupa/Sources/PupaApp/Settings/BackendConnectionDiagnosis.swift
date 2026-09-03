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
        guard let host = BackendConnectionDiagnosis.normalizeHost(host) else { return .publicInternet }
        if host == "localhost" || Self.isIPv6Loopback(host) { return .loopback }
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

    /// Strict dotted-quad parse. Deliberately rejects what `Int` would happily
    /// accept — `"+1"`, `" 1"`, and leading zeros, which resolvers read as
    /// octal, so `010.0.0.5` is 8.0.0.5 (public) and must not pass as RFC1918.
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count),
                  part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  part.count == 1 || part.first != "0",
                  let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// `::1` and the spellings of it that `URL.host` can hand back, plus the
    /// IPv4-mapped loopback forms. Not a full IPv6 parser — these are the ones
    /// a person actually types into the backend field.
    private static func isIPv6Loopback(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        switch bare {
        case "::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001",
             "::ffff:127.0.0.1", "::ffff:7f00:1":
            return true
        default:
            return false
        }
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
    ///
    /// This is about the *banner*, not about recoverability — whether the turn
    /// can still be picked up is `ChatViewModel.turnMayStillBeRunning`.
    var isTransient: Bool { cause == .dropped }

    /// Longest host shown in a message. Hostnames run to 253 characters, and
    /// the banner is three caption lines; past this the middle is elided.
    static let maxHostLength = 48
    /// Every message fits inside this, so the banner never has to truncate.
    static let maxMessageLength = 140

    private static let log = Logger(subsystem: "com.pupa-app.client", category: "backend")

    /// Lowercased, trailing-dot-stripped, or nil if there is nothing to show.
    /// A rooted FQDN (`pupa.tail1234.ts.net.`) is legal to paste into the
    /// backend field and must not defeat the suffix matching below.
    static func normalizeHost(_ host: String?) -> String? {
        guard var host = host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Host as shown to the user: normalized, and elided in the middle when
    /// long so both the machine name and the domain survive.
    static func displayHost(_ host: String?) -> String? {
        guard let host = normalizeHost(host) else { return nil }
        guard host.count > maxHostLength else { return host }
        let head = maxHostLength / 2 - 1
        let tail = maxHostLength - head - 1
        return "\(host.prefix(head))…\(host.suffix(tail))"
    }

    static func diagnose(_ error: Error, host: String? = nil) -> BackendConnectionDiagnosis {
        log.error("backend error host=\(host ?? "-", privacy: .private) \(String(describing: error), privacy: .public)")
        guard let urlError = error as? URLError else {
            return .init(cause: .unknown, message: genericMessage)
        }
        let kind = BackendHostKind.of(host)
        let shown = displayHost(host)
        // Two forms so a hostless message doesn't open with a lowercase word.
        let subject = shown.map { "“\($0)”" } ?? "The backend"
        let object = shown.map { "“\($0)”" } ?? "the backend"

        switch urlError.code {
        case .networkConnectionLost, .cancelled:
            // Chat hides this behind "Reconnecting…", but Settings' probes render
            // it verbatim — so it has to carry an action, not just a statement.
            return .init(cause: .dropped, message: "The connection dropped. Check your network and try again.")

        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .init(cause: .offline, message: "This device is offline. Check your network and try again.")

        case .cannotFindHost, .dnsLookupFailed:
            switch kind {
            case .tailnet:
                return .init(
                    cause: .hostNotFound,
                    message: "Can’t find \(object) — your Tailscale VPN looks disconnected. Turn it on, then try again."
                )
            case .privateNetwork:
                return .init(
                    cause: .hostNotFound,
                    message: "Can’t find \(object) — it’s a private name, so you may need a VPN or the right network."
                )
            case .loopback, .publicInternet:
                return .init(cause: .hostNotFound, message: "Can’t find \(object). Check the backend URL in Settings.")
            }

        case .cannotConnectToHost:
            switch kind {
            case .loopback:
                return .init(cause: .refused, message: "Nothing is listening on \(object). Start the backend.")
            case .tailnet:
                return .init(
                    cause: .refused,
                    message: "\(subject) refused the connection — check Tailscale is up and the backend is running."
                )
            case .privateNetwork, .publicInternet:
                return .init(cause: .refused, message: "\(subject) refused the connection. Check the backend is running.")
            }

        case .timedOut:
            switch kind {
            case .tailnet:
                return .init(
                    cause: .timedOut,
                    message: "\(subject) didn’t respond — check Tailscale is up and the backend is running."
                )
            case .loopback, .privateNetwork, .publicInternet:
                return .init(cause: .timedOut, message: "\(subject) didn’t respond in time. Check it’s running.")
            }

        case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection,
             .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .init(cause: .tls, message: "\(subject) refused a secure connection. Check its URL and certificate.")

        default:
            return .init(cause: .unknown, message: "Can’t reach \(object). Check it’s running and the URL is correct.")
        }
    }

    static let genericMessage = "Something went wrong talking to the backend. Please try again."
}
