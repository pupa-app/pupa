import Foundation
import PupaApp

/// A paired-device token held in memory for the life of one run.
///
/// The app keeps its token in the Keychain keyed by the backend's UUID, which a
/// harness root does not share — so a live run is handed its token instead
/// (`pupactl --token`, or `PUPA_CTL_TOKEN`). Nothing is written to the
/// Keychain, so driving a backend never disturbs the real app's pairing.
public struct TokenCredentialStore: BackendCredentialStore {
    private let token: String?

    public init(token: String?) {
        self.token = (token?.isEmpty ?? true) ? nil : token
    }

    public func token(for backendID: UUID) -> String? { token }
    public func setToken(_ token: String, for backendID: UUID) throws {}
    public func removeToken(for backendID: UUID) throws {}
}
