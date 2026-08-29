import SwiftUI
import PupaApp

@main
struct PupaHostApp: App {
    // This is the shipping `@main`, so the notification delegate has to be
    // attached here: an adaptor on any other `App` type is never instantiated,
    // and installing the delegate later than launch drops a cold-launch tap.
    @PupaAppDelegateAdaptor private var appDelegate: PupaAppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
