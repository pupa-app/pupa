import Foundation

/// A `.pupa` opened from outside the app (`onOpenURL`), staged for an explicit
/// confirm step before it touches the store — the source is untrusted and the
/// bundle's agent prompts run with the user's tools.
struct PendingImport: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let isLibrary: Bool
    /// Names of the app(s) that would be imported.
    let appNames: [String]
    /// Agent personas across the bundle, surfaced for review before import.
    let agentPrompts: [String]
    /// Automation rules the bundle carries. They're forced to propose rather
    /// than fire on their own (see `MyAppImporter.sanitizeAutomations`), but
    /// the user should still know the app reacts to what they do.
    let automationRuleCount: Int
}

/// Result/error surfaced after an external import attempt.
struct ImportNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

/// What an inbound import wants on screen. Both forms need the one
/// presentation slot `AppView` has, so both queue behind an open sheet.
enum ImportPresentation: Equatable {
    case confirm(PendingImport)
    case notice(ImportNotice)
}

/// Sequences an inbound import against `AppView`'s single presentation slot.
///
/// SwiftUI presents one sheet per view, and the marketplace is reached *from*
/// the Settings sheet ("Browse the marketplace"), so the install link comes
/// back with that sheet holding the slot. Assigning the confirm step straight
/// into it does nothing: it stays unpresented until the sheet is dismissed by
/// hand, which reads as an import that hangs (issue #323).
///
/// So an arrival while the slot is busy is *held*: `AppView` closes its sheets,
/// and every dismissal calls `slotFreed()` — after the dismissal completes, not
/// on a guessed delay. Ordering between the dismissal and a still-running
/// download doesn't matter; whichever lands second presents.
///
/// An alert is the one thing not closed from under the user: `.alert` has no
/// `onDismiss`, so nothing would report a programmatic clear and the hold would
/// never be released. The import waits for the user to acknowledge it instead.
struct ImportPresentationQueue {
    /// Presentable now — what `AppView` binds its confirm sheet and alert to.
    private(set) var active: ImportPresentation?
    /// Staged while the slot is busy. Promoted by `slotFreed()`.
    private(set) var held: ImportPresentation?
    /// True from the moment the slot was asked to free until it actually has.
    /// The `Bool` driving a sheet flips before the dismissal finishes, so it
    /// can't be the gate — staging in that window is the bug itself.
    private(set) var awaitingSlot = false

    /// A link arrived. `behindSheet` is whether any of `AppView`'s own sheets
    /// is on screen; the caller closes them.
    ///
    /// The app foregrounds on every tap, so a second link can arrive while the
    /// first is still in flight. The newest wins, matching the existing
    /// `remoteImport?.cancel()` contract.
    mutating func arrived(behindSheet: Bool) {
        held = nil
        guard behindSheet || active != nil else { return }
        awaitingSlot = true
        // A stale confirm sheet is closed; its `onDismiss` frees the slot.
        if case .confirm = active { active = nil }
    }

    /// The import resolved into something to show.
    mutating func stage(_ presentation: ImportPresentation) {
        if awaitingSlot {
            held = presentation
        } else {
            active = presentation
            held = nil
        }
    }

    /// A sheet finished dismissing. Called from every `sheet(onDismiss:)`.
    mutating func slotFreed() {
        awaitingSlot = false
        guard let held else { return }
        active = held
        self.held = nil
    }

    /// The confirm sheet is on its way out. Frees nothing — its `onDismiss`
    /// does that, once the dismissal has actually finished.
    mutating func clearActive() {
        active = nil
    }

    /// The user acknowledged the alert. Alerts have no `onDismiss`, so this is
    /// both halves at once.
    mutating func activeDismissed() {
        active = nil
        slotFreed()
    }

    /// `AppView`'s confirm-sheet binding.
    var confirm: PendingImport? {
        if case .confirm(let pending) = active { return pending }
        return nil
    }

    /// `AppView`'s alert binding.
    var notice: ImportNotice? {
        if case .notice(let note) = active { return note }
        return nil
    }
}
