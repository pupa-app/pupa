import SwiftUI
import PupaApp

#if canImport(AppKit)
import AppKit

/// SwiftPM-built macOS executables don't get a proper GUI activation policy
/// for free — without this the app launches in the background and no window
/// ever appears. The delegate sets `.regular` activation and brings the app
/// to the front on launch.
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `swift run` builds a bare binary with no Info.plist CFBundleIconFile,
        // so set the Dock/window icon programmatically from the bundled PNG.
        if let image = AppIcon.nsImage {
            NSApp.applicationIconImage = image
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

@main
struct DemoApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) var delegate
    #endif

    var body: some Scene {
        WindowGroup("Pupa") {
            AppView()
        }
    }
}
