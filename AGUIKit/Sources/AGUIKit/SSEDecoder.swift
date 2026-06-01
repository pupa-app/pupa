import Foundation

/// One frame parsed out of an SSE stream. Multiple `data:` lines in a single
/// frame are concatenated with newlines per the SSE spec.
public struct SSEFrame: Sendable, Equatable {
    public var event: String?
    public var id: String?
    public var data: String

    public init(event: String? = nil, id: String? = nil, data: String) {
        self.event = event
        self.id = id
        self.data = data
    }
}

/// Streaming SSE parser. Feed bytes via `feed(_:)` as they arrive; flushed
/// frames are returned each call. Holds state across calls so frames split
/// across `feed` boundaries are handled correctly.
///
/// Implements the subset of the SSE spec we need:
/// - Lines terminated by `\n`, `\r`, or `\r\n`.
/// - Field syntax: `field: value` (one space after the colon optional).
/// - Blank line dispatches the frame; non-`data`/`event`/`id` fields are ignored.
/// - Lines starting with `:` are comments (ignored).
public final class SSEDecoder: @unchecked Sendable {
    private var buffer: Data = Data()
    /// Per-frame accumulators reset on dispatch.
    private var pendingData: [String] = []
    private var pendingEvent: String?
    private var pendingId: String?

    public init() {}

    /// Append bytes and return any frames that completed.
    public func feed(_ bytes: Data) -> [SSEFrame] {
        buffer.append(bytes)
        var out: [SSEFrame] = []
        while let line = nextLine() {
            // Empty line dispatches.
            if line.isEmpty {
                if !pendingData.isEmpty {
                    out.append(SSEFrame(
                        event: pendingEvent,
                        id: pendingId,
                        data: pendingData.joined(separator: "\n")
                    ))
                }
                pendingData.removeAll(keepingCapacity: true)
                pendingEvent = nil
                pendingId = nil
                continue
            }
            if line.first == ":" {
                // Comment line. Ignore.
                continue
            }
            let (field, value) = splitFieldValue(line)
            switch field {
            case "data":  pendingData.append(value)
            case "event": pendingEvent = value
            case "id":    pendingId = value
            default:      break
            }
        }
        return out
    }

    /// Flush any in-flight frame (called when the stream terminates without a
    /// trailing blank line — SSE servers should always send one, but real
    /// transport might cut off early).
    public func finish() -> [SSEFrame] {
        guard !pendingData.isEmpty else { return [] }
        let frame = SSEFrame(
            event: pendingEvent,
            id: pendingId,
            data: pendingData.joined(separator: "\n")
        )
        pendingData.removeAll()
        pendingEvent = nil
        pendingId = nil
        return [frame]
    }

    // MARK: - Internals

    /// Pop the next complete line (any of \n, \r, \r\n) from the head of
    /// `buffer` and return it as a UTF-8 string. Returns nil if no line is
    /// fully buffered yet.
    ///
    /// Note on `Data` slicing: `Data` returned from `dropFirst(n)` keeps the
    /// underlying buffer but advances `startIndex` to `n`, so `bytes[0]` would
    /// be out of bounds. We always index via `bytes.startIndex + i` and copy
    /// (`Data(...)`) when reassigning so the next call sees `startIndex == 0`.
    private func nextLine() -> String? {
        var i = 0
        let bytes = buffer
        let start = bytes.startIndex
        let count = bytes.count
        while i < count {
            let b = bytes[start + i]
            if b == 0x0A { // \n
                let lineData = Data(bytes.prefix(i))
                buffer = Data(bytes.dropFirst(i + 1))
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            if b == 0x0D { // \r
                let lineData = Data(bytes.prefix(i))
                // Skip a following \n if present (CRLF).
                let nextStart = (i + 1 < count && bytes[start + i + 1] == 0x0A) ? i + 2 : i + 1
                buffer = Data(bytes.dropFirst(nextStart))
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            i += 1
        }
        return nil
    }

    private func splitFieldValue(_ line: String) -> (String, String) {
        guard let colonIdx = line.firstIndex(of: ":") else {
            // Whole line is the field name with empty value.
            return (line, "")
        }
        let field = String(line[..<colonIdx])
        var valueStart = line.index(after: colonIdx)
        // Optional single leading space after the colon.
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        return (field, String(line[valueStart...]))
    }
}
