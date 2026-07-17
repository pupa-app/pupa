import Foundation
import Observation

/// User-facing iCloud sync state for the Account screen. Distinct from
/// `PupaStorage.iCloudActive`, which only says the container URL resolved —
/// this reflects real convergence. The mirror runs off-main; `record` hops to
/// the main actor so SwiftUI re-renders.
@MainActor
@Observable
public final class SyncStatus {
    public static let shared = SyncStatus()
    private init() {}

    /// When the last converge pass finished (nil until the first one).
    public private(set) var lastConvergedAt: Date?
    /// Remote files still downloading (not yet `.current`) as of the last pass.
    public private(set) var pendingDownloads = 0

    /// Called from the off-main mirror at the end of every converge pass.
    nonisolated static func record(localChanged: Bool, pendingDownloads: Int) {
        Task { @MainActor in
            shared.lastConvergedAt = Date()
            shared.pendingDownloads = pendingDownloads
        }
    }
}
