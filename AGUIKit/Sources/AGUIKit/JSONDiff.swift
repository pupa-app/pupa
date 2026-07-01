import Foundation

/// A structural delta between two `AnyJSON` values. Stored on disk as a
/// snapshot's diff-from-parent so history keeps only what changed, not a
/// full copy of every state (see `SnapshotStore`).
///
/// A patch is directional: `apply(diff(a, b), to: a) == b`. Objects carry
/// per-key sub-patches plus a removed-key list; arrays carry a run-length
/// edit script (LCS-based) so appending one row to a 200-row tracker stores
/// one `insert`, not 201 elements.
public indirect enum JSONPatch: Codable, Hashable, Sendable {
    /// Replace the value wholesale (type change, scalar change, or a value
    /// with no cheaper structural delta).
    case replace(AnyJSON)
    /// Object delta: `set` maps keys to sub-patches (added keys use
    /// `.replace`), `remove` lists keys deleted from the parent.
    case object(set: [String: JSONPatch], remove: [String])
    /// Array delta: an ordered edit script transforming the parent array.
    case array([ArrayOp])
}

/// One run in an array edit script. Applied left-to-right against a cursor
/// walking the parent array.
public enum ArrayOp: Codable, Hashable, Sendable {
    /// Copy the next `n` parent elements unchanged.
    case keep(Int)
    /// Drop the next `n` parent elements.
    case remove(Int)
    /// Insert these new elements at the cursor.
    case insert([AnyJSON])
}

public enum JSONDiff {
    /// Minimal patch turning `from` into `to`, or `nil` if identical.
    public static func diff(_ from: AnyJSON, _ to: AnyJSON) -> JSONPatch? {
        if from == to { return nil }
        switch (from, to) {
        case let (.object(a), .object(b)):
            var set: [String: JSONPatch] = [:]
            var remove: [String] = []
            for key in a.keys where b[key] == nil { remove.append(key) }
            for (key, newVal) in b {
                if let oldVal = a[key] {
                    if let sub = diff(oldVal, newVal) { set[key] = sub }
                } else {
                    set[key] = .replace(newVal)
                }
            }
            // from != to guarantees at least one of set/remove is non-empty.
            return .object(set: set, remove: remove)
        case let (.array(a), .array(b)):
            let ops = arrayDiff(a, b)
            // All-keep can't happen when a != b, but guard anyway.
            if ops.count == 1, case .keep = ops[0] { return nil }
            return .array(ops)
        default:
            return .replace(to)
        }
    }

    /// Apply `patch` to `base`, producing the patched value.
    public static func apply(_ patch: JSONPatch, to base: AnyJSON) -> AnyJSON {
        switch patch {
        case .replace(let value):
            return value
        case .object(let set, let remove):
            var obj = base.objectValue ?? [:]
            for key in remove { obj[key] = nil }
            for (key, sub) in set {
                obj[key] = apply(sub, to: obj[key] ?? .null)
            }
            return .object(obj)
        case .array(let ops):
            return .array(applyArray(ops, to: base.arrayValue ?? []))
        }
    }

    // MARK: - Array diff (LCS)

    private enum RawOp: Equatable { case keep, remove, insert(AnyJSON) }

    private static func arrayDiff(_ a: [AnyJSON], _ b: [AnyJSON]) -> [ArrayOp] {
        let n = a.count, m = b.count
        // dp[i][j] = LCS length of a[i...] and b[j...].
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                            : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var raw: [RawOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { raw.append(.keep); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { raw.append(.remove); i += 1 }
            else { raw.append(.insert(b[j])); j += 1 }
        }
        while i < n { raw.append(.remove); i += 1 }
        while j < m { raw.append(.insert(b[j])); j += 1 }
        return coalesce(raw)
    }

    /// Merge consecutive same-kind raw ops into run-length `ArrayOp`s.
    private static func coalesce(_ raw: [RawOp]) -> [ArrayOp] {
        var ops: [ArrayOp] = []
        var keepRun = 0, removeRun = 0
        var insertRun: [AnyJSON] = []
        func flush() {
            if keepRun > 0 { ops.append(.keep(keepRun)); keepRun = 0 }
            if removeRun > 0 { ops.append(.remove(removeRun)); removeRun = 0 }
            if !insertRun.isEmpty { ops.append(.insert(insertRun)); insertRun = [] }
        }
        for op in raw {
            switch op {
            case .keep:
                if removeRun > 0 || !insertRun.isEmpty { flush() }
                keepRun += 1
            case .remove:
                if keepRun > 0 || !insertRun.isEmpty { flush() }
                removeRun += 1
            case .insert(let v):
                if keepRun > 0 || removeRun > 0 { flush() }
                insertRun.append(v)
            }
        }
        flush()
        return ops
    }

    private static func applyArray(_ ops: [ArrayOp], to base: [AnyJSON]) -> [AnyJSON] {
        var result: [AnyJSON] = []
        var cursor = 0
        for op in ops {
            switch op {
            case .keep(let count):
                let end = min(cursor + count, base.count)
                if cursor < end { result.append(contentsOf: base[cursor..<end]) }
                cursor = end
            case .remove(let count):
                cursor = min(cursor + count, base.count)
            case .insert(let values):
                result.append(contentsOf: values)
            }
        }
        return result
    }
}
