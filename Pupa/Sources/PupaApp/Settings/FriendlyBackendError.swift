import Foundation
import OSLog

/// Maps a raw networking `Error` to a short, human backend-connection
/// message. The raw error is logged (never shown) so the UI stays friendly.
/// Filter Console.app by subsystem `com.pupa-app.client`, category `backend`.
enum FriendlyBackendError {
    private static let log = Logger(subsystem: "com.pupa-app.client", category: "backend")

    /// Short user-facing copy for a failed backend request. Logs the raw error.
    static func message(for error: Error) -> String {
        log.error("backend error: \(String(describing: error), privacy: .public)")

        guard let urlError = error as? URLError else {
            return "Something went wrong talking to the backend. Please try again."
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "No internet connection. Check your network and try again."
        case .timedOut:
            return "The backend took too long to respond. Check it's running and try again."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Can't reach the backend — check the URL is correct and it's running."
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed:
            return "The backend refused a secure connection. Check its URL and certificate."
        default:
            return "Can't reach the backend — check it's running and the URL is correct."
        }
    }
}
