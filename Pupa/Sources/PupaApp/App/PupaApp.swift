import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Library-provided scene, for a host that wants the whole app in one symbol.
///
/// The shipping app declares its own `@main` instead and attaches
/// `PupaAppDelegate` there — mounting `RootView` alone is not enough. See
/// `PupaHostApp`. The macOS demo cannot: an `App` carries one
/// `NSApplicationDelegate` and `DemoApp` already spends it. That costs the demo
/// nothing, since an unsigned `swift run` binary has no bundle identifier and
/// `bootstrap()` no-ops there anyway.
public struct PupaApp: App {
    @PupaAppDelegateAdaptor private var appDelegate: PupaAppDelegate

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

/// Installs the `UNUserNotificationCenter` delegate from the platform launch
/// hook — the only point guaranteed to run before the OS dispatches a
/// cold-launch notification-tap response. Installing it later (e.g. in a view
/// `init`, under the splash) drops that launch tap: `didReceive` never fires,
/// so `pendingTap` is never parked and no chat opens.
///
/// Must be attached to whichever `App` carries `@main` — an adaptor on an
/// unused `App` type is never instantiated. Use `@PupaAppDelegateAdaptor`,
/// which picks the right adaptor per platform.
#if canImport(UIKit)
@MainActor
public final class PupaAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        NotificationCenterCoordinator.shared.bootstrap()
        return true
    }
}
#elseif canImport(AppKit)
@MainActor
public final class PupaAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenterCoordinator.shared.bootstrap()
    }
}
#endif

/// `@UIApplicationDelegateAdaptor` / `@NSApplicationDelegateAdaptor` are
/// distinct types, so every `@main` would otherwise repeat the same `#if`.
#if canImport(UIKit)
public typealias PupaAppDelegateAdaptor = UIApplicationDelegateAdaptor<PupaAppDelegate>
#elseif canImport(AppKit)
public typealias PupaAppDelegateAdaptor = NSApplicationDelegateAdaptor<PupaAppDelegate>
#endif
