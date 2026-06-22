import Testing
@testable import PupaApp

/// Tests for `ChatActivityStatus` — the badge state shared by the pupa circle
/// and thread lists. Locks the confirmed priority order
/// (actionRequired > error > unviewedAnswer > running > idle) and the
/// per-state badge descriptors.
@Suite("ChatActivityStatus")
struct ChatActivityStatusTests {

    @Test("Priority order: actionRequired > error > unviewedAnswer > running > idle")
    func priorityOrder() {
        #expect(ChatActivityStatus.actionRequired.priority > ChatActivityStatus.error.priority)
        #expect(ChatActivityStatus.error.priority > ChatActivityStatus.unviewedAnswer.priority)
        #expect(ChatActivityStatus.unviewedAnswer.priority > ChatActivityStatus.running.priority)
        #expect(ChatActivityStatus.running.priority > ChatActivityStatus.idle.priority)
    }

    @Test("max folds to the higher-priority status, regardless of argument order")
    func maxFolds() {
        #expect(ChatActivityStatus.max(.idle, .error) == .error)
        #expect(ChatActivityStatus.max(.error, .idle) == .error)
        #expect(ChatActivityStatus.max(.unviewedAnswer, .actionRequired) == .actionRequired)
        #expect(ChatActivityStatus.max(.error, .actionRequired) == .actionRequired)
        #expect(ChatActivityStatus.max(.idle, .idle) == .idle)
    }

    @Test("Badge: settled states have a symbol+color, running/idle do not")
    func badges() {
        #expect(ChatActivityStatus.actionRequired.badge?.symbol == "exclamationmark.circle.fill")
        #expect(ChatActivityStatus.error.badge?.symbol == "exclamationmark.octagon.fill")
        #expect(ChatActivityStatus.unviewedAnswer.badge?.symbol == "exclamationmark.circle.fill")
        #expect(ChatActivityStatus.running.badge == nil)
        #expect(ChatActivityStatus.idle.badge == nil)
    }

    @Test("idle alone has no accessibility description; the others do")
    func accessibility() {
        #expect(ChatActivityStatus.idle.accessibilityDescription == nil)
        #expect(ChatActivityStatus.running.accessibilityDescription != nil)
        #expect(ChatActivityStatus.actionRequired.accessibilityDescription != nil)
    }
}
