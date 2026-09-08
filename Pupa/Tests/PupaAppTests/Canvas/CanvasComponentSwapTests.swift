#if os(macOS)
import Foundation
import Testing
import SwiftUI
import AppKit
@testable import PupaApp

/// The guard the three view-state leak fixes shipped without: drive a **real**
/// `CanvasView` through a component swap and assert state did not carry over.
///
/// This is the only layer that can catch the bug class. `CanvasView` renders one
/// component into a single structural slot with no `.id(...)`, so a component
/// view's `@State` is reused when another component of the same kind takes that
/// slot. Constructing two views directly proves nothing — each gets fresh
/// `@State` by construction. The swap has to happen inside one hosted view.
///
/// Serialized and disk-touching: `CanvasView` needs a `ChatSessionCoordinator`,
/// whose `init` writes `AGENTS.md` under `PupaStorage.activeRoot`.
@MainActor
@Suite("Canvas component swap", .serialized)
struct CanvasComponentSwapTests {

    init() { TestStorage.activate() }

    private func makeCoordinator(_ store: MyAppStore) -> ChatSessionCoordinator {
        let memRoot = TestStorage.root
            .appendingPathComponent("swap-\(UUID().uuidString)")
        return ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: memRoot),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        )
    }

    /// Two calendars in one MyApp, months a year apart. Same kind and same
    /// MyApp is the case that actually aliases: `makeView` returns `AnyView`,
    /// and SwiftUI only reuses state when the wrapped type is unchanged.
    private func twoCalendars() -> (store: MyAppStore, myAppId: UUID, first: String, second: String) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let app = MyApp(name: "A", iconSystemName: "calendar", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([app], app.id))

        let first = store.addComponent(
            kind: "calendar", name: "One", iconSystemName: "calendar", myAppId: app.id)!
        let second = store.addComponent(
            kind: "calendar", name: "Two", iconSystemName: "calendar", myAppId: app.id)!

        _ = store.addCalendarEvent(
            CalendarEvent(title: "Early", start: "2025-01-15T09:00:00Z"),
            myAppId: app.id, componentId: first)
        _ = store.addCalendarEvent(
            CalendarEvent(title: "Late", start: "2026-11-20T09:00:00Z"),
            myAppId: app.id, componentId: second)

        // The month grid is what holds the seeded `@State`; `.list` is the default.
        _ = store.setCalendarViewMode(.month, myAppId: app.id, componentId: first)
        _ = store.setCalendarViewMode(.month, myAppId: app.id, componentId: second)

        return (store, app.id, first, second)
    }

    private func host(
        _ store: MyAppStore,
        _ coordinator: ChatSessionCoordinator,
        _ selection: SidebarSelection
    ) -> NSHostingView<CanvasView> {
        let view = NSHostingView(
            rootView: CanvasView(store: store, selection: selection, coordinator: coordinator))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func month(_ date: Date) -> (year: Int, month: Int) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return (c.year ?? 0, c.month ?? 0)
    }

    /// The regression. Calendar A anchors its grid on its first event (Jan
    /// 2025); swapping calendar B into the same slot must re-anchor on B's
    /// first event (Nov 2026). Before the fix the `@State` seeded in
    /// `CalendarMonthBody.init` survived the swap and B rendered A's month —
    /// an empty grid, which is exactly what the anchor exists to prevent.
    @Test("A second calendar in the same slot shows its own month")
    func calendarMonthDoesNotSurviveASwap() throws {
        let (store, myAppId, first, second) = twoCalendars()
        let coordinator = makeCoordinator(store)

        CanvasStateProbe.reset()
        let view = host(store, coordinator, .myAppComponent(myAppId, first))
        let afterFirst = try #require(CanvasStateProbe.calendarMonths.last)
        #expect(month(afterFirst) == (2025, 1), "calendar one anchors on its own event")

        // Swap in place: same hosting view, same root type, so SwiftUI diffs
        // rather than rebuilding — the real structural-reuse condition.
        _ = store.setActiveComponent(componentId: second, myAppId: myAppId)
        view.rootView = CanvasView(
            store: store, selection: .myAppComponent(myAppId, second), coordinator: coordinator)
        view.layoutSubtreeIfNeeded()

        let afterSecond = try #require(CanvasStateProbe.calendarMonths.last)
        #expect(
            month(afterSecond) == (2026, 11),
            "calendar two kept calendar one's month — view state survived the swap")
    }

    /// The identity itself: each component must resolve its own key, and the
    /// same key again on return. Everything keyed on `CanvasComponentKey`
    /// inherits its correctness from this.
    @Test("Each component resolves its own key, and the same one on return")
    func componentKeyTracksTheRenderedComponent() throws {
        let (store, myAppId, first, second) = twoCalendars()
        let coordinator = makeCoordinator(store)

        CanvasStateProbe.reset()
        let view = host(store, coordinator, .myAppComponent(myAppId, first))
        let keyA = try #require(CanvasStateProbe.keys.last)

        view.rootView = CanvasView(
            store: store, selection: .myAppComponent(myAppId, second), coordinator: coordinator)
        view.layoutSubtreeIfNeeded()
        let keyB = try #require(CanvasStateProbe.keys.last)

        view.rootView = CanvasView(
            store: store, selection: .myAppComponent(myAppId, first), coordinator: coordinator)
        view.layoutSubtreeIfNeeded()
        let keyAAgain = try #require(CanvasStateProbe.keys.last)

        #expect(keyA != keyB, "two components in one MyApp must not share a key")
        #expect(keyA == keyAAgain, "returning to a component must resolve its original key")
        #expect(keyA.myAppId == myAppId)
        #expect(keyA.componentId == first)
        #expect(keyB.componentId == second)
    }
}
#endif
