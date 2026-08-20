#if DEBUG
/// Disk-access counters, DEBUG only.
///
/// Assertions on I/O counts are deterministic where timing assertions are
/// flaky, so this is how the suite pins "this path reads a small index, not
/// the whole history". Generalises `SnapshotStore.fullDecodeCount`, which
/// already guarded the History listing the same way.
///
/// Not synchronised: the disk suites run serially (`make test` pins Pupa's
/// `--no-parallel`) and share one process-global `PupaStorage.overrideRoot`
/// for the same reason.
enum DiskIO {
    /// `CloudDocument.read` calls.
    nonisolated(unsafe) static var reads = 0
    /// Bytes those reads pulled off disk.
    nonisolated(unsafe) static var bytesRead = 0
    /// `MemoryStore` recursive tree scans.
    nonisolated(unsafe) static var scans = 0
    /// Per-entry metadata syscalls issued while scanning.
    nonisolated(unsafe) static var statCalls = 0

    static func reset() {
        reads = 0
        bytesRead = 0
        scans = 0
        statCalls = 0
    }
}
#endif
