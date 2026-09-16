import Foundation
import Testing
@testable import PupaApp

/// `setActive` writes only `index.json` now, instead of going through
/// `persist()` and re-encoding every app body to discover that nothing else
/// changed. The active-app pointer lives in that index, so this is the test
/// that the shortcut still persists it — a regression reads as "relaunch
/// reopens the wrong app".
@MainActor
@Suite("Active app persistence", .serialized)
struct ActiveAppPersistenceTests {

    init() { TestStorage.activate() }

    @Test("picking a MiniApp survives a relaunch")
    func setActiveSurvivesReload() async {
        // Disk suites share one process-global root; without this the reload
        // below can pick up another suite's roster. Observed as a rare
        // spurious failure under load.
        await MiniAppStore.clearStorage()
        MiniAppTypeRegistry.shared.registerBuiltins()
        let store = MiniAppStore(initial: nil)
        let first = store.addMiniApp(
            typeId: MiniAppType.tracker.id, name: "Persist A", iconSystemName: "square")
        let second = store.addMiniApp(
            typeId: MiniAppType.tracker.id, name: "Persist B", iconSystemName: "circle")
        // `addMiniApp` leaves the app it just made active.
        #expect(store.activeMiniAppId == second)

        store.setActive(first)
        #expect(store.activeMiniAppId == first)

        let reloaded = MiniAppStore(initial: nil)
        #expect(reloaded.activeMiniAppId == first, "active app did not survive the reload")
    }
}
