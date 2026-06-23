import SwiftUI

/// App entry point. Use `@main PupaApp` from your iOS App target, or
/// the `PupaDemo` executable on macOS for fast iteration.
public struct PupaApp: App {
    public init() {
        // Resolve the iCloud container off-main and, the first time it becomes
        // available, lift any offline-created local data into it — before the
        // stores load. Both are no-ops when iCloud is unavailable.
        PupaStorage.warm()
        PupaStorage.promoteLocalIfNeeded()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
