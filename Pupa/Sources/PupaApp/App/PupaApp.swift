import SwiftUI

/// App entry point. Use `@main PupaApp` from your iOS App target, or
/// the `PupaDemo` executable on macOS for fast iteration.
public struct PupaApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
