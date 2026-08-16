import Foundation

/// One frontend call's on-device progress within the current interrupt batch.
///
/// `result == nil` means the handler was entered but never returned a value on
/// record — the app died mid-call, so whether its side effect landed is
/// genuinely unknown.
public struct FrontendCallRecord: Codable, Sendable, Equatable {
    public var name: String
    public var result: AnyJSON?

    public init(name: String, result: AnyJSON? = nil) {
        self.name = name
        self.result = result
    }

    public var isFinished: Bool { result != nil }
}

/// Host-supplied, per-thread record of frontend-tool dispatch progress.
///
/// The backend parks with its SSE closed while the client runs a frontend tool
/// (pupa#258). If the app is killed before it POSTs `command.resume`, the
/// result is lost — and on relaunch nothing distinguishes a call that never ran
/// from one that ran and only failed to report. Re-dispatching blind would
/// double-apply side effects (`addComponent`, calendar writes).
///
/// So the session records each call as it starts and as it finishes. A
/// relaunched app replays `finished` results verbatim, reports `started` ones
/// as incomplete, and runs only what has no entry at all.
///
/// AGUIKit owns no storage; the host supplies the persistence. A `nil` journal
/// disables the feature — every call simply runs, which is the pre-#258
/// behaviour.
public protocol FrontendDispatchJournal: Sendable {
    /// About to invoke `callId`'s handler.
    func noteStarted(callId: String, name: String) async
    /// `callId`'s handler returned `result`.
    func noteFinished(callId: String, result: AnyJSON) async
    /// Everything recorded for this thread, keyed by `toolCallId`.
    func restore() async -> [String: FrontendCallRecord]
    /// Drop the thread's record — the batch it described has been delivered.
    func clear() async
}
