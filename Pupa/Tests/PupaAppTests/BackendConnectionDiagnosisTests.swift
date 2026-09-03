import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// The point of the diagnosis layer: a backend that can't be reached should say
/// *why*, and for a tailnet host the likeliest why is "the VPN is off". Before
/// this, every transport failure collapsed into one calm "Reconnecting…".
@Suite("Backend connection diagnosis")
struct BackendConnectionDiagnosisTests {

    // MARK: - Host classification

    @Test("Tailscale hosts are recognised by MagicDNS name and CGNAT address")
    func hostKind_tailnet() {
        #expect(BackendHostKind.of("pupa.tail9f2c.ts.net") == .tailnet)
        #expect(BackendHostKind.of("PUPA.TAIL9F2C.TS.NET") == .tailnet)
        #expect(BackendHostKind.of("100.101.102.103") == .tailnet)   // 100.64.0.0/10
        #expect(BackendHostKind.of("100.64.0.1") == .tailnet)
        #expect(BackendHostKind.of("100.127.255.254") == .tailnet)
        // Just outside the CGNAT range — public, not tailnet.
        #expect(BackendHostKind.of("100.63.0.1") == .publicInternet)
        #expect(BackendHostKind.of("100.128.0.1") == .publicInternet)
    }

    @Test("loopback, LAN and public hosts each classify on their own")
    func hostKind_others() {
        #expect(BackendHostKind.of("localhost") == .loopback)
        #expect(BackendHostKind.of("127.0.0.1") == .loopback)
        #expect(BackendHostKind.of("::1") == .loopback)
        #expect(BackendHostKind.of("192.168.1.20") == .privateNetwork)
        #expect(BackendHostKind.of("10.0.0.5") == .privateNetwork)
        #expect(BackendHostKind.of("172.16.0.9") == .privateNetwork)
        #expect(BackendHostKind.of("172.32.0.9") == .publicInternet)   // outside /12
        #expect(BackendHostKind.of("mac-mini.local") == .privateNetwork)
        #expect(BackendHostKind.of("mac-mini") == .privateNetwork)     // bare MagicDNS/mDNS name
        #expect(BackendHostKind.of("api.example.com") == .publicInternet)
        #expect(BackendHostKind.of(nil) == .publicInternet)
    }

    // MARK: - Transience

    @Test("only a drop under a live connection is transient")
    func transience() {
        #expect(BackendConnectionDiagnosis.diagnose(URLError(.networkConnectionLost)).isTransient)
        #expect(BackendConnectionDiagnosis.diagnose(URLError(.cancelled)).isTransient)
        for code: URLError.Code in [
            .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut,
            .notConnectedToInternet, .secureConnectionFailed, .badServerResponse,
        ] {
            #expect(
                !BackendConnectionDiagnosis.diagnose(URLError(code)).isTransient,
                "\(code) needs the user to act — it must not hide behind Reconnecting…"
            )
        }
    }

    // MARK: - The tailnet case

    @Test("a tailnet host that won't resolve blames the VPN by name")
    func tailnetDNSFailure_namesTheVPN() {
        let d = BackendConnectionDiagnosis.diagnose(URLError(.cannotFindHost), host: "pupa.tail9f2c.ts.net")
        #expect(d.cause == .hostNotFound)
        #expect(d.message.contains("Tailscale"))
        #expect(d.message.contains("pupa.tail9f2c.ts.net"))
        #expect(!d.isTransient)
    }

    @Test("a tailnet host that refuses or times out mentions both the VPN and the backend")
    func tailnetRefusedAndTimeout() {
        let refused = BackendConnectionDiagnosis.diagnose(URLError(.cannotConnectToHost), host: "100.101.102.103")
        #expect(refused.cause == .refused)
        #expect(refused.message.contains("Tailscale"))

        let timedOut = BackendConnectionDiagnosis.diagnose(URLError(.timedOut), host: "pupa.tail9f2c.ts.net")
        #expect(timedOut.cause == .timedOut)
        #expect(timedOut.message.contains("Tailscale"))
    }

    @Test("a public host is never blamed on the VPN")
    func publicHost_noVPNAdvice() {
        for code: URLError.Code in [.cannotFindHost, .cannotConnectToHost, .timedOut] {
            let d = BackendConnectionDiagnosis.diagnose(URLError(code), host: "api.example.com")
            #expect(!d.message.contains("Tailscale"), "\(code) on a public host must not blame the VPN")
        }
    }

    // MARK: - The other common causes

    @Test("nothing listening on localhost says so instead of blaming the network")
    func loopbackRefused() {
        let d = BackendConnectionDiagnosis.diagnose(URLError(.cannotConnectToHost), host: "localhost")
        #expect(d.cause == .refused)
        #expect(d.message.contains("Nothing is listening"))
    }

    @Test("device offline is reported as the device, not the backend")
    func offline() {
        let d = BackendConnectionDiagnosis.diagnose(URLError(.notConnectedToInternet), host: "pupa.tail9f2c.ts.net")
        #expect(d.cause == .offline)
        #expect(d.message.contains("offline"))
        #expect(!d.message.contains("Tailscale"))  // the VPN is not the problem here
    }

    @Test("a TLS refusal points at the certificate")
    func tls() {
        #expect(BackendConnectionDiagnosis.diagnose(URLError(.serverCertificateUntrusted)).cause == .tls)
        #expect(BackendConnectionDiagnosis.diagnose(URLError(.secureConnectionFailed)).cause == .tls)
    }

    @Test("a non-URLError falls back to the generic message, never a raw dump")
    func nonURLError() {
        struct Boom: Error { let internals = "raw stack trace, host paths, all of it" }
        let d = BackendConnectionDiagnosis.diagnose(Boom())
        #expect(d.cause == .unknown)
        #expect(d.message == BackendConnectionDiagnosis.genericMessage)
        #expect(!d.message.contains("Boom"))
    }

    @Test("every message stays short enough for the inline chat banner")
    func messagesAreShort() {
        let hosts: [String?] = [nil, "localhost", "pupa.tail9f2c.ts.net", "192.168.1.20", "api.example.com"]
        let codes: [URLError.Code] = [
            .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
            .cannotConnectToHost, .timedOut, .secureConnectionFailed, .badServerResponse,
        ]
        for host in hosts {
            for code in codes {
                let message = BackendConnectionDiagnosis.diagnose(URLError(code), host: host).message
                #expect(!message.isEmpty)
                #expect(message.count <= 120, "too long for the banner (\(message.count)): \(message)")
            }
        }
    }

    // MARK: - Chat wiring

    @MainActor
    @Test("the chat banner surfaces the diagnosis for a stream that failed to connect")
    func chatBanner_usesDiagnosis() {
        let state = ChatViewModel.connectionState(
            for: AgentClientError.requestFailed(URLError(.cannotFindHost)),
            host: "pupa.tail9f2c.ts.net"
        )
        guard case .failed(let message) = state else {
            Issue.record("expected a failed banner, got \(state)")
            return
        }
        #expect(message.contains("Tailscale"))
    }

    @MainActor
    @Test("non-transport failures keep the fixed generic banner")
    func chatBanner_nonTransport() {
        #expect(
            ChatViewModel.connectionState(for: AgentClientError.httpStatus(500, body: "Traceback…"))
                == .failed(ChatViewModel.backendErrorMessage)
        )
    }
}
