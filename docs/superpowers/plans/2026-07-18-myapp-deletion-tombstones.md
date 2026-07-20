# MyApp Deletion Tombstones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A MyApp deletion writes a durable, mirrored tombstone so the delete sticks across devices and relaunches, and union-load never resurrects a deleted app.

**Architecture:** Per-id marker files `state/tombstones/<uuid>.json` (`{id, deletedAt}`) mirror via `StorageMirror` like app bodies. `removeMyApp` writes one; `load()`'s union subtracts tombstoned ids; the orphan sweep reaps a tombstoned body; a 180-day GC drops old tombstones. No auto-merge — twins are pruned manually and the tombstone makes the prune propagate.

**Tech Stack:** Swift, Swift Testing (`Testing`), Foundation file I/O via `CloudDocument`.

## Global Constraints

- Run the suite with `make test` (never raw `swift test`); narrow with `make test FILTER=TombstoneTests`.
- Storage tests: `@MainActor`, `@Suite(..., .serialized)`, `init() { TestStorage.activate() }`, reset with `await MyAppStore.clearStorage()`. Serial run only (shared `overrideRoot`).
- Bump `PupaAppVersion` patch-only: `0.0.208` → `0.0.209` (`Pupa/Sources/PupaApp/Version.swift`).
- Add one CHANGELOG entry under `0.0.107`.
- Succinct docstrings. No personal info / developer names / machine paths in the repo. Commit co-author line `Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` (repo convention); never sign a human developer.
- Breaking changes acceptable (pre-stable) — no back-compat shims.
- All edits in `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` unless noted.

---

### Task 1: Tombstone store primitives

Add the `Tombstone` type, its on-disk paths, `writeTombstone`, and `diskTombstoneIds`. These back every later task.

**Files:**
- Modify: `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` (path helpers block ~3118-3144)
- Test: `Pupa/Tests/PupaAppTests/TombstoneTests.swift` (create)

**Interfaces:**
- Consumes: `stateRoot`, `appsDir`, `stateEncoder()`, `CloudDocument.write/read/delete` (existing).
- Produces:
  - `nonisolated static func writeTombstone(_ id: UUID, at now: Date = Date())`
  - `private nonisolated static func diskTombstoneIds() -> Set<UUID>`
  - `private nonisolated static var tombstonesDir: URL` / `tombstoneURL(_ id:) -> URL`
  - `private struct Tombstone: Codable { var id: UUID; var deletedAt: Date }`

- [ ] **Step 1: Write the failing test**

Create `Pupa/Tests/PupaAppTests/TombstoneTests.swift`:

```swift
import Foundation
import Testing
@testable import PupaApp

/// Durable MyApp deletion tombstones (`state/tombstones/<uuid>.json`): a delete
/// must survive relaunch + sync, and union-load must never resurrect it.
@MainActor
@Suite("MyApp deletion tombstones", .serialized)
struct TombstoneTests {

    init() { TestStorage.activate() }

    private var stateRoot: URL { PupaStorage.stateRoot }
    private func bodyURL(_ id: UUID) -> URL {
        stateRoot.appendingPathComponent("apps/\(id.uuidString).json")
    }
    private func tombstoneURL(_ id: UUID) -> URL {
        stateRoot.appendingPathComponent("tombstones/\(id.uuidString).json")
    }

    @Test("writeTombstone creates a decodable marker discoverable on disk")
    func writeTombstoneRoundTrips() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        MyAppStore.writeTombstone(id)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(id).path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=TombstoneTests`
Expected: FAIL — compile error, `writeTombstone` is not a member of `MyAppStore`.

- [ ] **Step 3: Write minimal implementation**

In `MyAppStore.swift`, immediately after `diskAppIds()` (ends ~3132) and before `struct IndexFile`, insert:

```swift
    // MARK: - Deletion tombstones

    /// A durable, mirrored "this app id is deleted" marker. Lives under
    /// `state/tombstones/<uuid>.json` so it syncs like an app body. Union-load
    /// subtracts tombstoned ids; the orphan sweep reaps their bodies.
    private struct Tombstone: Codable {
        var id: UUID
        var deletedAt: Date
    }

    private nonisolated static var tombstonesDir: URL {
        stateRoot.appendingPathComponent("tombstones", isDirectory: true)
    }
    private nonisolated static func tombstoneURL(_ id: UUID) -> URL {
        tombstonesDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Record `id` as deleted. Durable + mirrored, so the delete survives a
    /// relaunch and reaches every device. Re-deleting just refreshes `deletedAt`.
    nonisolated static func writeTombstone(_ id: UUID, at now: Date = Date()) {
        guard let data = try? stateEncoder().encode(Tombstone(id: id, deletedAt: now)) else { return }
        try? CloudDocument.write(data, to: tombstoneURL(id))
    }

    /// UUIDs of every `tombstones/<uuid>.json` on disk. Ids come from filenames
    /// (no decode) so even a half-written tombstone still suppresses its app.
    private nonisolated static func diskTombstoneIds() -> Set<UUID> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tombstonesDir.path) else { return [] }
        return Set(names.compactMap { name in
            name.hasSuffix(".json") ? UUID(uuidString: String(name.dropLast(".json".count))) : nil
        })
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test FILTER=TombstoneTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Pupa/Sources/PupaApp/MyApps/MyAppStore.swift Pupa/Tests/PupaAppTests/TombstoneTests.swift
git commit -m "feat(sync): add MyApp deletion tombstone primitives

Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: union-load subtracts tombstones

Make `load()` exclude any tombstoned id, even when the body is still on disk.

**Files:**
- Modify: `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` `load()` (~3279-3293)
- Test: `Pupa/Tests/PupaAppTests/TombstoneTests.swift`

**Interfaces:**
- Consumes: `diskTombstoneIds()`, `writeTombstone` (Task 1).
- Produces: no new symbols; behavior change to `load()`.

- [ ] **Step 1: Write the failing test**

Append to `TombstoneTests`:

```swift
    @Test("a tombstoned id is absent from the roster even with its body on disk")
    func tombstoneSuppressesBodyInLoad() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let kept = a.addMyApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        #expect(FileManager.default.fileExists(atPath: bodyURL(doomed).path))

        MyAppStore.writeTombstone(doomed)          // mark deleted; body deliberately left on disk

        let b = MyAppStore()                        // reload via union-load
        #expect(!b.myApps.contains { $0.id == doomed })   // suppressed
        #expect(b.myApps.contains { $0.id == kept })      // untouched
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=TombstoneTests/tombstoneSuppressesBodyInLoad`
Expected: FAIL — `doomed` still loaded (union-load reads the body; no subtraction yet).

- [ ] **Step 3: Write minimal implementation**

In `load()`, replace the union block (from `var seen = Set<UUID>()` through the recovery `for` loop, ~3279-3293) with:

```swift
            let tombstoned = diskTombstoneIds()
            var seen = Set<UUID>()
            var apps: [MyApp] = []
            for id in index.order {                       // index order first; tolerate missing/corrupt
                guard !tombstoned.contains(id) else { continue }   // deleted → never load
                guard seen.insert(id).inserted else { continue }
                if let d = CloudDocument.read(appURL(id)), let app = try? dec.decode(MyApp.self, from: d) {
                    apps.append(app)
                }
            }
            // Recover any on-disk body the index omitted (minus tombstoned),
            // appended id-sorted so the roster is deterministic across launches.
            for id in diskAppIds().subtracting(seen).subtracting(tombstoned).sorted(by: { $0.uuidString < $1.uuidString }) {
                if let d = CloudDocument.read(appURL(id)), let app = try? dec.decode(MyApp.self, from: d) {
                    apps.append(app)
                }
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test FILTER=TombstoneTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Pupa/Sources/PupaApp/MyApps/MyAppStore.swift Pupa/Tests/PupaAppTests/TombstoneTests.swift
git commit -m "fix(sync): union-load subtracts tombstoned MyApp ids

Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: removeMyApp writes a tombstone

Wire the durable marker into the actual delete path so a real delete can't resurrect.

**Files:**
- Modify: `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` `removeMyApp` (~349-359)
- Test: `Pupa/Tests/PupaAppTests/TombstoneTests.swift`

**Interfaces:**
- Consumes: `writeTombstone` (Task 1), tombstone-aware `load()` (Task 2).
- Produces: `removeMyApp` now writes `tombstoneURL(id)`.

- [ ] **Step 1: Write the failing test**

Append to `TombstoneTests`:

```swift
    @Test("removeMyApp writes a tombstone and a re-pushed body does not resurrect")
    func removeWritesTombstoneNoResurrect() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let kept = a.addMyApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        let body = try Data(contentsOf: bodyURL(doomed))   // capture before delete

        a.removeMyApp(doomed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))  // durable marker
        #expect(!FileManager.default.fileExists(atPath: bodyURL(doomed).path))      // body gone

        try body.write(to: bodyURL(doomed))                // another device re-pushes the stale body

        let b = MyAppStore()                                // reload
        #expect(!b.myApps.contains { $0.id == doomed })     // still dead (tombstone wins)
        #expect(b.myApps.contains { $0.id == kept })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=TombstoneTests/removeWritesTombstoneNoResurrect`
Expected: FAIL — no tombstone file (assert on `tombstoneURL` fails); re-pushed body resurrects `doomed`.

- [ ] **Step 3: Write minimal implementation**

In `removeMyApp` (~349-359), after `userInitiatedRemovals.insert(id)`, add the tombstone write:

```swift
        userInitiatedRemovals.insert(id)
        // Durable, mirrored delete marker — survives relaunch and suppresses the
        // body on every device, so a not-yet-synced copy can't resurrect it.
        Self.writeTombstone(id)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test FILTER=TombstoneTests`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add Pupa/Sources/PupaApp/MyApps/MyAppStore.swift Pupa/Tests/PupaAppTests/TombstoneTests.swift
git commit -m "fix(sync): removeMyApp records a durable deletion tombstone

Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: orphan sweep reaps tombstoned bodies

A tombstoned body is not recovery material — delete it regardless of decodability or age, so an arriving tombstone reaps the second device's copy.

**Files:**
- Modify: `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` `sweepOrphanAppFiles` (~3206-3231)
- Test: `Pupa/Tests/PupaAppTests/TombstoneTests.swift`

**Interfaces:**
- Consumes: `diskTombstoneIds()` (Task 1).
- Produces: `sweepOrphanAppFiles` now deletes tombstoned bodies.

- [ ] **Step 1: Write the failing test**

Append to `TombstoneTests`:

```swift
    @Test("the orphan sweep reaps a tombstoned body but keeps live ones")
    func sweepReapsTombstonedBody() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let live = a.addMyApp(typeId: "tracker", name: "Live", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        MyAppStore.writeTombstone(doomed)                  // fresh body, but tombstoned

        _ = MyAppStore.sweepOrphanAppFiles(keeping: [])     // nothing pinned as live

        #expect(!FileManager.default.fileExists(atPath: bodyURL(doomed).path))  // reaped despite being fresh + decodable
        #expect(FileManager.default.fileExists(atPath: bodyURL(live).path))     // decodable, not tombstoned → kept
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=TombstoneTests/sweepReapsTombstonedBody`
Expected: FAIL — `doomed` body kept (the #200 decodable-body guard preserves it; no tombstone reap yet).

- [ ] **Step 3: Write minimal implementation**

In `sweepOrphanAppFiles`, add the tombstone set before the loop and a reap branch inside it. The loop body (~3214-3228) becomes:

```swift
        let tombstoned = diskTombstoneIds()
        for name in names {
            guard name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(".json".count))),
                  !live.contains(id) else { continue }
            let url = appsDir.appendingPathComponent(name)
            // A tombstoned body is a confirmed delete, not recovery material —
            // reap it regardless of decodability or age so the delete propagates.
            if tombstoned.contains(id) {
                CloudDocument.delete(url)
                deleted += 1
                continue
            }
            // Never delete a file that still decodes as a real MyApp body: a
            // stale/lost index can de-list an app without deleting it, and that
            // body is recovery material (union-load restores it), not an orphan.
            // Only genuine junk (undecodable / partial) ages out.
            if let data = CloudDocument.read(url),
               (try? JSONDecoder().decode(MyApp.self, from: data)) != nil { continue }
            guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) > minAge else { continue }
            CloudDocument.delete(url)
            deleted += 1
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test FILTER=TombstoneTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Pupa/Sources/PupaApp/MyApps/MyAppStore.swift Pupa/Tests/PupaAppTests/TombstoneTests.swift
git commit -m "fix(sync): orphan sweep reaps tombstoned MyApp bodies

Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: tombstone GC + init wiring

Drop tombstones older than 180 days so they can't accumulate, and run GC where the sweep already runs.

**Files:**
- Modify: `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` — new `gcTombstones` (near `sweepOrphanAppFiles`) + init call site (~124)
- Test: `Pupa/Tests/PupaAppTests/TombstoneTests.swift`

**Interfaces:**
- Consumes: `tombstonesDir`, `tombstoneURL`, `Tombstone`, `writeTombstone(_:at:)` (Task 1).
- Produces: `nonisolated static func gcTombstones(ttl: TimeInterval = 180 * 24 * 3600, now: Date = Date()) -> Int`.

- [ ] **Step 1: Write the failing test**

Append to `TombstoneTests`:

```swift
    @Test("GC drops tombstones past the TTL and keeps recent ones")
    func gcDropsExpiredTombstones() async throws {
        await MyAppStore.clearStorage()
        let old = UUID(), recent = UUID()
        MyAppStore.writeTombstone(old, at: Date(timeIntervalSinceNow: -200 * 24 * 3600))
        MyAppStore.writeTombstone(recent)

        let dropped = MyAppStore.gcTombstones()   // default 180-day TTL, now = Date()

        #expect(dropped == 1)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(old).path))     // expired → gone
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(recent).path))   // fresh → kept
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test FILTER=TombstoneTests/gcDropsExpiredTombstones`
Expected: FAIL — compile error, `gcTombstones` undefined.

- [ ] **Step 3: Write minimal implementation**

Add after `sweepOrphanAppFiles` (after ~3231):

```swift
    /// Drop tombstones older than `ttl`. Tiny files, but unbounded otherwise.
    /// The TTL is generous so a tombstone always outlives an un-synced stale
    /// body (bodies sweep at 7 days). Returns the number GC'd.
    @discardableResult
    nonisolated static func gcTombstones(
        ttl: TimeInterval = 180 * 24 * 3600,
        now: Date = Date()
    ) -> Int {
        let dec = JSONDecoder()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tombstonesDir.path) else { return 0 }
        var gcd = 0
        for name in names where name.hasSuffix(".json") {
            let url = tombstonesDir.appendingPathComponent(name)
            guard let data = CloudDocument.read(url),
                  let t = try? dec.decode(Tombstone.self, from: data),
                  now.timeIntervalSince(t.deletedAt) > ttl else { continue }
            CloudDocument.delete(url)
            gcd += 1
        }
        return gcd
    }
```

Then in `init` (~124), add the GC call right after the sweep:

```swift
                Self.sweepOrphanAppFiles(keeping: Set(myApps.map(\.id)))
                Self.gcTombstones()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test FILTER=TombstoneTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Commit**

```bash
git add Pupa/Sources/PupaApp/MyApps/MyAppStore.swift Pupa/Tests/PupaAppTests/TombstoneTests.swift
git commit -m "feat(sync): GC MyApp tombstones past a 180-day TTL

Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: docs, version bump, full-suite gate

Reflect reality in docs, bump the version, and prove the whole suite green (no regression to `RosterUnionLoadTests` / `OrphanSweepTests`).

**Files:**
- Modify: `docs/architecture.md` (Persistence section)
- Modify: `CHANGELOG.md`
- Modify: `Pupa/Sources/PupaApp/Version.swift`

**Interfaces:** none (docs + version).

- [ ] **Step 1: Run the full suite (regression gate)**

Run: `make test`
Expected: PASS — all suites green, including `RosterUnionLoadTests` (a de-listed but **not** tombstoned body still recovers) and `OrphanSweepTests` (decodable-body-kept guard still holds for non-tombstoned bodies). If any fail, stop and fix before continuing.

- [ ] **Step 2: Update architecture.md**

In `docs/architecture.md`, Persistence section, add a paragraph describing the deletion lifecycle:

```markdown
**Deletion tombstones.** Deleting a MyApp writes a durable, mirrored marker
`state/tombstones/<uuid>.json` (`{id, deletedAt}`) in addition to removing the
body. Union-load subtracts tombstoned ids, so a not-yet-synced copy on another
device can never resurrect a deleted app; the orphan sweep reaps a tombstoned
body regardless of age. A tombstone beats a concurrent body edit (delete is
sticky). Tombstones GC after 180 days.
```

- [ ] **Step 3: Update CHANGELOG.md**

Add under a new `0.0.107` entry:

```markdown
## 0.0.107

### Fixed
- Deleting a MyApp now sticks across devices — iCloud sync no longer resurrects
  a deleted app, and duplicate apps can be pruned for good.
```

- [ ] **Step 4: Bump PupaAppVersion**

In `Pupa/Sources/PupaApp/Version.swift`, change `0.0.208` to `0.0.209`:

```swift
public let PupaAppVersion: String = "0.0.209"
```

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md CHANGELOG.md Pupa/Sources/PupaApp/Version.swift
git commit -m "docs(sync): document MyApp deletion tombstones; bump 0.0.209

Co-authored-by: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- `writeTombstone`, `sweepOrphanAppFiles`, `gcTombstones` are `nonisolated static` and internal, so `@testable import PupaApp` reaches them. `Tombstone`, `tombstonesDir`, `tombstoneURL`, `diskTombstoneIds` stay `private` (tested via behavior).
- `clearStorage()` already `removeItem(at: stateRoot)` — recursive — so `state/tombstones/` is wiped with everything else. No change needed there.
- `CloudDocument.write`/`.delete` create parent dirs and schedule a mirror reconcile, so tombstone files auto-create and auto-sync. No StorageMirror change required.
- Do not touch the UUID identity model or the seed/`restoreExample` creation path — out of scope (see spec).
- After the plan lands and merges to `dev`, the TestFlight re-archive (held 0.0.208) runs against `0.0.209`.
