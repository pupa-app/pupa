import Foundation
import os

/// Tiny diagnostic logger.
///
/// - **Debug builds**: ON by default, printed to stdout via FileHandle so
///   `swift run` shows them in the terminal even when the app activates as
///   a GUI process.
/// - **Release builds**: OFF by default.
/// - Override either way via env var `AGUIKIT_LOG=1` / `AGUIKIT_LOG=0` before
///   the process starts, or by setting `AGUIKitLog.enabled` programmatically.
///
/// Output uses stable prefixes for grep:
///   `[AGUIKit clt] …`  – AgentClient: HTTP + raw events
///   `[AGUIKit ses] …`  – AgentSession: round + tool dispatch
///   `[AGUIKit prb] …`  – host turn-state probe (driven launches only)
///
/// Every line is also mirrored to the unified log under subsystem
/// `dev.pupa.aguikit`, because a simulator-launched app's stderr goes
/// nowhere a test runner can read:
///
///     xcrun simctl spawn booted log stream --level info \
///       --predicate 'subsystem BEGINSWITH "dev.pupa"'
public enum AGUIKitLog {
    nonisolated(unsafe) public static var enabled: Bool = {
        if let v = ProcessInfo.processInfo.environment["AGUIKIT_LOG"] {
            return !v.isEmpty && v != "0" && v.lowercased() != "false"
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Write directly to stderr's underlying file descriptor. `print` can
    /// occasionally be buffered or routed to the unified log when the
    /// process is a foreground GUI app; this guarantees the terminal sees
    /// each line immediately.
    private static func emit(_ line: String, _ log: OSLog = AGUIKitLog.sessionLog) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
        // `%{public}@` is load-bearing: without it the message redacts to
        // `<private>` and the trace is useless.
        os_log("%{public}@", log: log, type: .info, line)
    }

    private static let sessionLog = OSLog(subsystem: "dev.pupa.aguikit", category: "session")
    private static let probeLog = OSLog(subsystem: "dev.pupa.aguikit", category: "probe")

    public static func client(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        emit("[AGUIKit clt] \(message())")
    }

    public static func session(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        emit("[AGUIKit ses] \(message())")
    }

    /// Host turn state, one line per change. Its own category so a trace can
    /// isolate the state series from the round narrative — and the only
    /// channel that keeps reporting while the app is backgrounded, where
    /// there is no accessibility tree to query.
    ///
    /// Not gated on `enabled`: a driven launch always wants it, and nothing
    /// else calls it.
    public static func probe(_ message: @autoclosure () -> String) {
        emit("[AGUIKit prb] \(message())", probeLog)
    }

    /// Compact one-line label for an `AgentEvent` so logs stay scannable.
    public static func shortLabel(_ event: AgentEvent) -> String {
        switch event {
        case .runStarted(let s):       return "RUN_STARTED runId=\(s.runId), threadId=\(s.threadId)"
        case .runFinished(let f):      return "RUN_FINISHED runId=\(f.runId), threadId=\(f.threadId)"
        case .runError(let e):         return "RUN_ERROR \(e.message)"
        case .textMessageStart(let s): return "TEXT_START messageId=\(s.messageId)"
        case .textMessageContent(let c): return "TEXT_CONTENT messageId=\(c.messageId) +\(c.delta.count)c"
        case .textMessageEnd(let e):   return "TEXT_END messageId=\(e.messageId)"
        case .toolCallStart(let s):    return "TOOL_START call=\(s.toolCallId) name=\(s.toolCallName)"
        case .toolCallArgs(let a):     return "TOOL_ARGS call=\(a.toolCallId) +\(a.delta.count)c"
        case .toolCallEnd(let e):      return "TOOL_END call=\(e.toolCallId)"
        case .toolCallResult(let r):   return "TOOL_RESULT call=\(r.toolCallId)"
        case .stateSnapshot:           return "STATE_SNAPSHOT"
        case .stateDelta:              return "STATE_DELTA"
        case .messagesSnapshot(let s): return "MESSAGES_SNAPSHOT n=\(s.messages.count)"
        case .stepStarted(let s):      return "STEP_STARTED \(s.stepName)"
        case .stepFinished(let s):     return "STEP_FINISHED \(s.stepName)"
        case .raw:                     return "RAW"
        case .custom(let c):           return "CUSTOM \(c.name)"
        case .unknown(let t, _):       return "UNKNOWN type=\(t)"
        }
    }
}
