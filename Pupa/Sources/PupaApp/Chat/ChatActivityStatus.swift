import SwiftUI

/// At-a-glance state of one chat thread, surfaced as a badge on the collapsed
/// pupa circle and the thread lists. Derived live from a `ChatViewModel`
/// (see `ChatViewModel.activityStatus`); a scope folds its threads' statuses to
/// the highest-priority one via `aggregateStatus`.
public enum ChatActivityStatus: Equatable {
    case idle
    /// Streaming — model generating or tools running.
    case running
    /// A turn finished but the user hasn't looked at this thread since.
    case unviewedAnswer
    /// The last turn ended in an error (`connectionIssue == .failed`).
    case error
    /// Parked on a human-in-the-loop interrupt (shell approval / question).
    case actionRequired

    /// Higher wins when several threads (or a thread in several states) fold
    /// together: actionRequired > error > unviewedAnswer > running > idle.
    var priority: Int {
        switch self {
        case .idle: return 0
        case .running: return 1
        case .unviewedAnswer: return 2
        case .error: return 3
        case .actionRequired: return 4
        }
    }

    /// The higher-priority of two statuses.
    static func max(_ a: ChatActivityStatus, _ b: ChatActivityStatus) -> ChatActivityStatus {
        a.priority >= b.priority ? a : b
    }

    /// SF Symbol + tint for the settled states. `nil` for `idle`/`running`
    /// (running renders a spinner, idle renders nothing).
    var badge: (symbol: String, color: Color)? {
        switch self {
        case .actionRequired: return ("exclamationmark.circle.fill", .orange)
        case .error: return ("exclamationmark.octagon.fill", .red)
        case .unviewedAnswer: return ("exclamationmark.circle.fill", .accentColor)
        case .running, .idle: return nil
        }
    }

    /// VoiceOver description; `nil` when there's nothing to announce.
    var accessibilityDescription: String? {
        switch self {
        case .idle: return nil
        case .running: return "Working"
        case .unviewedAnswer: return "New answer"
        case .error: return "Error"
        case .actionRequired: return "Action required"
        }
    }
}

/// Small badge view shared by the pupa circle, the thread dropdown, and the
/// Agents dashboard. Renders a spinner while `running`, a colored exclamation
/// for the settled states, and nothing when `idle`.
struct StatusBadge: View {
    let status: ChatActivityStatus
    var size: CGFloat = 14

    var body: some View {
        Group {
            if status == .running {
                ProgressView()
                    .controlSize(.mini)
            } else if let badge = status.badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white, badge.color)
                    .background(Circle().fill(.white).padding(2))
            }
        }
        .accessibilityHidden(status.accessibilityDescription == nil)
        .accessibilityLabel(status.accessibilityDescription ?? "")
    }
}
