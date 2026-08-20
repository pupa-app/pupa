import Foundation
import PupaApp

/// Deterministic latency harness for the navigation hot paths.
///
/// Off unless `PUPA_PERF_DRIVE=1`. With `PUPA_PERF_SEED=1` it first writes a
/// fixed corpus under a temp `PupaStorage.overrideRoot`, so numbers compare
/// across runs and machines — the reason the ad-hoc measurements in #154 and
/// #183 can't be compared to each other today.
///
/// This benchmarks the *store-level* work a tap performs, not synthesized
/// taps: gesture recognition was never the problem, the runloop turn the tap
/// kicks off is. Real tap→frame numbers come from `PerfTrace` inside the app
/// (`PUPA_PERF=1`), which reports the same interactions under a human.
///
/// Run:
/// `PUPA_PERF=1 PUPA_PERF_DRIVE=1 PUPA_PERF_SEED=1 swift run -c release --package-path Pupa PupaDemo`
@MainActor
enum PerfDriver {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PUPA_PERF_DRIVE"] == "1"
    }

    private static let warmups = 3
    private static let reps = 20

    // Fixture shape. Fixed, so the corpus is identical every run.
    private static let appCount = 8
    private static let snapshotsPerApp = 100
    private static let pinsPerApp = 3
    private static let memoryFilesPerApp = 40
    private static let subagentsPerApp = 6
    private static let componentsPerApp = 12

    /// Seed (optionally), measure, print. Returns after reporting; the caller
    /// exits rather than showing a window.
    static func run() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-perf-fixture", isDirectory: true)
        PupaStorage.overrideRoot = root

        var apps: [MyApp] = []
        if ProcessInfo.processInfo.environment["PUPA_PERF_SEED"] == "1" {
            try? FileManager.default.removeItem(at: root)
            print("seeding \(appCount) apps × \(snapshotsPerApp) snapshots …")
            apps = seed(at: root)
        } else {
            // Reconstruct just enough of the roster to address the corpus: the
            // snapshot dirs on disk are the source of truth for which app ids
            // exist, and every measured path keys off the id.
            apps = SnapshotStore.allAppIds().compactMap { id in
                SnapshotStore.pinnedMetas(id).first.flatMap { SnapshotStore.restoredApp(id, id: $0.id) }
            }
        }
        guard let target = apps.first else {
            print("no apps in fixture — rerun with PUPA_PERF_SEED=1")
            return
        }
        print("corpus: \(apps.count) apps, \(SnapshotStore.allAppIds().count) snapshot dirs, \(byteCount(of: root)) on disk\n")

        print("path,p50ms,p90ms")
        // RC2 — every one of these reads and JSON-parses whole snapshot files.
        measure("SnapshotStore.metas") { _ = SnapshotStore.metas(target.id) }
        measure("hasAnyPinnedSnapshots (Settings gate)") {
            _ = MyAppStore(initial: (apps, target.id)).hasAnyPinnedSnapshots
        }
        measure("SnapshotStore.record(.edit)") { i in
            var edited = target
            edited.name = "edit-\(i)"
            _ = SnapshotStore.record(edited, reason: .edit)
        }
        // RC1 — what mounting the Agents pane costs on a MyApp switch.
        measure("MemoryStore(appRoot) init — recursive scan") {
            _ = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: target.id))
        }
        measure("AgentStore(memory:) — subagent discovery") {
            let mem = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: target.id))
            _ = AgentStore(memory: mem).agents
        }
    }

    // MARK: - Measurement

    private static func measure(_ name: String, _ body: (Int) -> Void) {
        for i in 0..<warmups { body(-i - 1) }
        var samples: [Double] = []
        samples.reserveCapacity(reps)
        for i in 0..<reps {
            let start = ContinuousClock.now
            body(i)
            let d = (ContinuousClock.now - start).components
            samples.append(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
        }
        samples.sort()
        print(String(format: "%@,%.1f,%.1f", name, percentile(samples, 0.5), percentile(samples, 0.9)))
    }

    private static func measure(_ name: String, _ body: @escaping () -> Void) {
        measure(name) { _ in body() }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.down)))
        return sorted[idx]
    }

    // MARK: - Fixture

    @discardableResult
    private static func seed(at root: URL) -> [MyApp] {
        var apps: [MyApp] = []
        for a in 0..<appCount {
            let components = (1...componentsPerApp).map { c in
                Component(
                    id: "tracker-\(c)",
                    name: "Component \(c)",
                    iconSystemName: "list.bullet",
                    body: .empty
                )
            }
            let app = MyApp(
                name: "Perf App \(a)",
                iconSystemName: "square.grid.2x2",
                typeId: "tracker",
                components: components
            )
            apps.append(app)

            // Snapshot history: `.edit` dedups on an unchanged head, so vary
            // the payload each round the way real edits do.
            for s in 0..<snapshotsPerApp {
                var edited = app
                edited.name = "Perf App \(a) rev \(s)"
                _ = SnapshotStore.record(edited, reason: .edit)
            }
            for p in 0..<pinsPerApp {
                var pinned = app
                pinned.name = "Perf App \(a) pin \(p)"
                _ = SnapshotStore.record(pinned, reason: .pinned, label: "pin \(p)")
            }

            let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: app.id))
            for f in 0..<memoryFilesPerApp {
                _ = try? memory.writeFile(
                    path: "notes/note-\(f).md",
                    content: String(repeating: "note body \(f)\n", count: 40))
            }
            for g in 0..<subagentsPerApp {
                _ = try? memory.writeFile(
                    path: "\(MemoryStore.pupaAgentsDir)/agent-\(g)/AGENTS.md",
                    content: """
                        ---
                        name: Agent \(g)
                        description: Seeded perf fixture subagent \(g)
                        ---

                        Body for agent \(g).
                        """)
            }
        }
        return apps
    }

    private static func byteCount(of root: URL) -> String {
        var total = 0
        if let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
