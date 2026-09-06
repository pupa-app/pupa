import Foundation

/// Successful response from `POST /auth/pair`. Mirrors the backend's
/// `_PairExchangeRequest` reply shape.
public struct PairingResult: Sendable {
    public let deviceID: UUID
    public let token: String
    public let label: String
    public let scopes: [String]
}

public enum PairingError: Error, CustomStringConvertible {
    case invalidCode
    case unexpectedResponse(status: Int, body: String)
    case decoding
    /// `host` so the message can name what it failed to reach — a dead
    /// tailnet is the commonest way pairing fails.
    case transport(any Error, host: String?)

    public var description: String {
        switch self {
        case .invalidCode:
            return "The pairing code is unknown or has already been used / expired"
        case .unexpectedResponse(let status, let body):
            return "Backend returned HTTP \(status): \(body)"
        case .decoding:
            return "Couldn't decode the backend's response"
        case .transport(let error, let host):
            return FriendlyBackendError.message(for: error, host: host)
        }
    }
}

/// Tiny URLSession-backed client that redeems a bootstrap code for a
/// permanent device token. Public path on the backend — no Authorization
/// header is sent (the code IS the credential).
public struct BackendPairingClient: Sendable {
    public let backendURL: URL
    private let session: URLSession

    public init(backendURL: URL, session: URLSession = .shared) {
        self.backendURL = backendURL
        self.session = session
    }

    public func pair(code: String, label: String) async throws -> PairingResult {
        let url = backendURL.appendingPathComponent("auth/pair")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The backend's pairing alphabet is uppercase only, but operators
        // sometimes paste lowercase. Normalise client-side so the user
        // doesn't get a confusing 404.
        let normalisedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let body: [String: String] = ["code": normalisedCode, "label": label]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PairingError.transport(error, host: backendURL.host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.unexpectedResponse(status: -1, body: "")
        }
        if http.statusCode == 404 {
            throw PairingError.invalidCode
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw PairingError.unexpectedResponse(status: http.statusCode, body: bodyText)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceIDString = payload["deviceId"] as? String,
              let deviceID = UUID(uuidString: deviceIDString),
              let token = payload["token"] as? String,
              let returnedLabel = payload["label"] as? String,
              let scopes = payload["scopes"] as? [String]
        else {
            throw PairingError.decoding
        }
        return PairingResult(deviceID: deviceID, token: token, label: returnedLabel, scopes: scopes)
    }
}
