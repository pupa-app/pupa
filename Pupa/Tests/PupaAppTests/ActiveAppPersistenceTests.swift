import Foundation
import Testing
@testable import PupaApp

/// `setActive` writes only `index.json` now, instead of going through
/// `persist()` and re-encoding every app body to discover that nothing else
/// changed. The active-app pointer lives in that index, so this is the test
/// that the shortcut still persists it — a regression reads as "relaunch
/// reopens the wrong app".
@MainActor
@Suite("Active app persistence")
struct ActiveAppPersistenceTests {

    init() { TestStorage.activate() }

    @Test("picking a MyApp survives a relaunch")
    func setActiveSurvivesReload() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let store = MyAppStore(initial: nil)
        let first = store.addMyApp(
            typeId: MyAppType.tracker.id, name: "Persist A", iconSystemName: "square")
        let second = store.addMyApp(
            typeId: MyAppType.tracker.id, name: "Persist B", iconSystemName: "circle")
        // `addMyApp` leaves the app it just made active.
        #expect(store.activeMyAppId == second)

        store.setActive(first)
        #expect(store.activeMyAppId == first)

        let reloaded = MyAppStore(initial: nil)
        #expect(reloaded.activeMyAppId == first, "active app did not survive the reload")
    }
}
