import SwiftUI

/// App entry point. Use `@main PupaApp` from your iOS App target, or
/// the `PupaDemo` executable on macOS for fast iteration.
public struct PupaApp: App {
    public init() {
        // Stores load from the local canonical tree immediately (no iCloud on
        // the launch path). `warm()` resolves the iCloud container off-main and
        // kicks the first background mirror pass to converge with iCloud.
        PupaStorage.warm()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
