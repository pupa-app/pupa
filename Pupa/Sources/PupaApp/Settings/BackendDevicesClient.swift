import Foundation

public enum DevicesError: Error, CustomStringConvertible {
    case unauthorized
    case unexpectedResponse(status: Int, body: String)
    case decoding
    /// `host` so the message can name what it failed to reach — a dead
    /// tailnet is the commonest way pairing fails.
    case transport(any Error, host: String?)

    public var description: String {
        switch self {
        case .unauthorized:
            return "Not authorised — device token may have been revoked"
        case .unexpectedResponse(let status, let body):
            return "Backend returned HTTP \(status): \(body)"
        case .decoding:
            return "Couldn't decode the backend's response"
        case .transport(let error, let host):
            return FriendlyBackendError.message(for: error, host: host)
        }
    }
}

/// Authenticated client for `DELETE /auth/devices/{id}` — used to revoke this
/// device on the backend during Unpair. Requires a valid device token in
/// `authHeaders`.
public struct BackendDevicesClient: Sendable {
    public let backendURL: URL
    public let authHeaders: [String: String]
    private let session: URLSession

    public init(backendURL: URL, authHeaders: [String: String], session: URLSession = .shared) {
        self.backendURL = backendURL
        self.authHeaders = authHeaders
        self.session = session
    }

    public func revokeDevice(id: String) async throws {
        let url = backendURL.appendingPathComponent("auth/devices/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in authHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw DevicesError.transport(error, host: backendURL.host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DevicesError.unexpectedResponse(status: -1, body: "")
        }
        if http.statusCode == 401 { throw DevicesError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DevicesError.unexpectedResponse(status: http.statusCode, body: body)
        }
    }
}
