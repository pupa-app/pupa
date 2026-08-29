import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// App entry point. Use `@main PupaApp` from your iOS App target, or
/// the `PupaDemo` executable on macOS for fast iteration.
public struct PupaApp: App {
    #if canImport(UIKit)
    /// Installs the `UNUserNotificationCenter` delegate from the UIKit launch
    /// hook — the only point guaranteed to run before iOS dispatches a
    /// cold-launch notification-tap response. Setting it later (e.g. in a view
    /// `init`, under the splash) drops that launch tap: `didReceive` never fires,
    /// so `pendingTap` is never parked and no chat opens. See `PupaAppDelegate`.
    @UIApplicationDelegateAdaptor(PupaAppDelegate.self) private var appDelegate
    #endif

    public init() {
        // Stores load from the local canonical tree immediately (no iCloud on
        // the launch path). `warm()` resolves the iCloud container off-main and
        // kicks the first background mirror pass to converge with iCloud.
        PupaStorage.warm()
        #if !canImport(UIKit)
        // AppKit/demo entry has no UIApplication launch hook; `App.init` runs
        // before the scene, so install the notification delegate here instead.
        NotificationCenterCoordinator.shared.bootstrap()
        #endif
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

#if canImport(UIKit)
/// Bridges UIKit's launch into SwiftUI so the notification delegate is live
/// before the OS delivers a cold-launch tap. Nothing else belongs here — the
/// app's real wiring stays in SwiftUI (`RootView` / `AppView`).
@MainActor
final class PupaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCenterCoordinator.shared.bootstrap()
        return true
    }
}
#endif
