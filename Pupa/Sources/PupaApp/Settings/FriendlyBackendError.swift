import Foundation

/// Maps a raw networking `Error` to a short, human backend-connection message.
/// Thin wrapper over `BackendConnectionDiagnosis`, which owns the copy and the
/// logging — pass `host` and the message names the actual fix (VPN off, nothing
/// listening) instead of the generic fallback.
enum FriendlyBackendError {
    /// Short user-facing copy for a failed backend request. Logs the raw error.
    static func message(for error: Error, host: String? = nil) -> String {
        BackendConnectionDiagnosis.diagnose(error, host: host).message
    }
}
