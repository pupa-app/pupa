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
        // so set the Dock/window icon programmatically. macOS won't auto-mask a
        // raw square here, so use the squircle-masked variant to match the
        // shipped app's Dock silhouette.
        if let image = AppIcon.macDockImage ?? AppIcon.nsImage {
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

    init() {
        // `PUPA_PERF_DRIVE=1` turns the demo into the latency harness: measure,
        // report, exit. No window — it must not race the UI for the main actor.
        if PerfDriver.isRequested {
            PerfDriver.run()
            exit(0)
        }
        // UI mode keeps the window: the interactions being measured are view
        // cost, so they need a live view tree.
        if PerfDriver.isUIRequested {
            PerfDriver.prepareUI()
            PerfDriver.runUI()
        }
    }

    var body: some Scene {
        WindowGroup("Pupa") {
            RootView()
        }
    }
}
