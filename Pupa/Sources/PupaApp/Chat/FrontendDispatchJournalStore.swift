import Foundation
import AGUIKit

/// On-disk record of one thread's in-flight frontend-tool dispatch (pupa#258).
///
/// Written while the backend is parked waiting for `command.resume`, so an app
/// killed mid-dispatch can answer the parked turn on relaunch with the results
/// it actually produced instead of re-running side-effecting tools.
///
/// Local-only: lives at `activeRoot/dispatch/`, outside the mirrored `state/`
/// subtree. The record describes what *this device* did in a process that no
/// longer exists; syncing it to another device would be meaningless at best.
///
/// A scratch file, not a log: one file per thread, one entry per call in the
/// current batch, overwritten in place and dropped as soon as its results ship.
actor FrontendDispatchJournalStore: FrontendDispatchJournal {
    private let threadId: String
    /// Mirrors the file so a batch's reads don't hit disk repeatedly.
    private var records: [String: FrontendCallRecord]

    init(threadId: String) {
        self.threadId = threadId
        self.records = Self.read(threadId) ?? [:]
    }

    // MARK: - FrontendDispatchJournal

    func noteStarted(callId: String, name: String) {
        records[callId] = FrontendCallRecord(name: name)
        flush()
    }

    func noteFinished(callId: String, result: AnyJSON) {
        records[callId] = FrontendCallRecord(name: records[callId]?.name ?? "", result: result)
        flush()
    }

    func restore() -> [String: FrontendCallRecord] { records }

    func clear() {
        guard !records.isEmpty || FileManager.default.fileExists(atPath: Self.url(threadId).path) else { return }
        records.removeAll()
        try? FileManager.default.removeItem(at: Self.url(threadId))
    }

    private func flush() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(records) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: Self.url(threadId), options: .atomic)
    }

    // MARK: - Files

    nonisolated static var dir: URL {
        PupaStorage.activeRoot.appendingPathComponent("dispatch", isDirectory: true)
    }

    nonisolated static func url(_ threadId: String) -> URL {
        dir.appendingPathComponent("\(threadId).json")
    }

    private nonisolated static func read(_ threadId: String) -> [String: FrontendCallRecord]? {
        guard let data = try? Data(contentsOf: url(threadId)) else { return nil }
        return try? JSONDecoder().decode([String: FrontendCallRecord].self, from: data)
    }

    /// Drop the record for `threadId`. Silent if already gone.
    nonisolated static func delete(_ threadId: String) {
        try? FileManager.default.removeItem(at: url(threadId))
    }

    /// Drop records for every id in `threadIds`.
    nonisolated static func delete(_ threadIds: some Sequence<String>) {
        for id in threadIds { delete(id) }
    }

    /// Delete records last written more than `age` ago. Run at launch.
    ///
    /// The backend's park wall is 300s, so a record older than that can never be
    /// resumed; a day is comfortably past it and leaves manual inspection room.
    /// Returns how many files were removed.
    @discardableResult
    nonisolated static func sweep(olderThan age: TimeInterval = 24 * 60 * 60) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}
