# MyApp deletion tombstones

Durable, mirrored delete markers so a MyApp deletion sticks across devices
and relaunches, and union-load never resurrects a deleted app.

## Problem

`load()` rebuilds the roster as `union(index.order, decodable apps/<uuid>.json
on disk)` (MyAppStore.swift `load()`, the #200 union-load). Membership keys on
UUID only. Deletion has **no durable record**: `removeMyApp` inserts the id into
the in-memory `userInitiatedRemovals` set and lets `persist()` remove the local
body file. That set is never written to disk or mirrored.

Consequences:

- **Delete-resurrect race.** Device A deletes X (local body removed, delete
  queued to mirror). Device B still holds body X. If B union-loads and
  re-persists before its mirror pulls the delete, B re-writes body X and pushes
  it back — X returns on A. After an app relaunch on A, `userInitiatedRemovals`
  is empty and A's own union-load re-adopts any resurrected body.
- **Can't prune duplicates.** Same-name/different-UUID twins (residual from the
  earlier iCloud wipe-and-reseed divergence, made visible by union-load) cannot
  be reliably deleted — the whole point of the cleanup the user needs.

Identity model is **not** the problem: `MyApp.id = UUID()` at creation is stable
and travels with the body across sync. Each creation is its own identity. The
gap is the **deletion** half of the lifecycle.

## Approach

A delete writes a **tombstone**: a durable, mirrored marker "id X is dead."
Union-load subtracts tombstoned ids; sync deletes the body when a tombstone
arrives. No auto-merge — the user prunes twins manually; tombstones make those
prunes stick everywhere.

Rejected alternatives:

- *Merge-by-name on load* — collapses legitimately-distinct same-name apps;
  violates "creation defines identity."
- *Deterministic ids from name/template* — conflicts with per-creation identity;
  doesn't help user-created same-name apps.
- *One-time cleanup migration only* — no ongoing guard; dupes recur and deletes
  still don't stick.

## Components

### 1. Tombstone store — `state/tombstones/<uuid>.json`

Per-id marker files, each `{ id: UUID, deletedAt: Date }`. Per-id (not one
`tombstones.json`) so two devices deleting concurrently union cleanly, exactly
like app bodies — no whole-file last-writer-wins conflict that could drop a
tombstone. Lives under `state/` so `StorageMirror` mirrors it with no new sync
wiring.

New helpers on `MyAppStore` (mirroring the `appURL`/`diskAppIds` shape):

- `tombstonesDir` / `tombstoneURL(_ id:)` — paths.
- `writeTombstone(_ id:)` — encode `{id, deletedAt: now}` via `CloudDocument.write`.
- `static diskTombstoneIds() -> Set<UUID>` — decode all `tombstones/<uuid>.json`,
  return the id set (ignore undecodable). Backs union-load subtraction and sweep.

### 2. `removeMyApp` writes a tombstone

After removing from `myApps` and before/with `persist()`, call
`writeTombstone(id)`. Keep the existing `userInitiatedRemovals.insert(id)` — it
still drives the surprise-removal banner suppression (a deliberate delete is not
a "surprise"). The tombstone is the *durable* record; `userInitiatedRemovals`
stays the *session* record.

### 3. `load()` union subtracts tombstones

Roster = `union(index.order, diskAppIds()).subtracting(diskTombstoneIds())`.
Applied to both branches of the union (index-order ids and disk-recovered ids).
A tombstone suppresses a body even when the body is still on disk (the mirror
hasn't deleted it yet on this device).

### 4. Sync reconcile deletes tombstoned bodies

`sweepOrphanAppFiles(keeping:)` currently *preserves* any decodable body (#200
defense-in-depth). Add: a body whose id is in `diskTombstoneIds()` is deleted
regardless of decodability or age — a tombstoned body is not recovery material.
This is how an arriving tombstone reaps the local body on the second device.

### 5. Conflict rule — tombstone beats concurrent body edit

If a tombstone and a live/edited body for the same id coexist, the tombstone
wins (the app stays deleted). Simpler and matches user intent (a prune must
stick); a concurrent edit on another device is lost, acceptable pre-stable.
Enforced structurally by (3) and (4): subtraction + reaping, no special mirror
logic needed.

### 6. Tombstone GC

Tombstones are tiny but must not accumulate unbounded. GC a tombstone once
`now - deletedAt > 180 days`. The TTL is generous so a tombstone always outlives
any un-synced stale body (bodies sweep at 7 days; a device offline for months is
the only way a stale body could outlive a shorter TTL). GC runs where
`sweepOrphanAppFiles` already runs (init / reconcile). A GC'd tombstone whose
body is already gone everywhere is inert; if a stale body somehow survived past
180 days it could re-adopt, an accepted edge.

## Data flow

```
removeMyApp(X)
  ├─ myApps.remove(X)
  ├─ userInitiatedRemovals.insert(X)     // session: banner suppression
  ├─ writeTombstone(X)                   // durable: state/tombstones/X.json  → mirrors
  └─ persist()                           // deletes local apps/X.json, rewrites index

Device B reconcile
  ├─ mirror pulls tombstones/X.json
  ├─ sweepOrphanAppFiles: X tombstoned → delete apps/X.json
  └─ load(): union(...).subtracting({X}) → X absent from roster

Any device, any relaunch
  └─ load() subtracts diskTombstoneIds() → X can never resurrect
```

## Testing (TDD — failing tests first)

New `TombstoneTests` (`.serialized`, `TestStorage` isolation per storage-test
rules: `overrideRoot` + `cloudMirrorOverride`, `await clearStorage()` /
`withCloudMirror`, drain/epoch):

- `deleteStaysDeletedAcrossReload` — delete X, write a stale body X back to disk
  (simulating another device's copy), `reloadFromDisk` → X absent (tombstone
  subtracts it). The core regression.
- `tombstoneSuppressesRemoteBodyAndSweepReapsIt` — body X + tombstone X on disk →
  union-load excludes X; `sweepOrphanAppFiles` deletes body X.
- `tombstoneWinsOverConcurrentBody` — edited body X + tombstone X → X excluded.
- `tombstoneGCAfterTTL` — tombstone older than 180 d is dropped; younger kept.
- Regression: existing `RosterUnionLoadTests` stay green — a de-listed body that
  is **not** tombstoned still recovers (union-load unchanged for that path).
- `clearStorage()` also clears `state/tombstones/` (fresh-device tests truly fresh).

## Files

- `Pupa/Sources/PupaApp/MyApps/MyAppStore.swift` — `tombstonesDir`/`tombstoneURL`/
  `writeTombstone`/`diskTombstoneIds`; `removeMyApp` tombstone write; `load()`
  union subtraction; `sweepOrphanAppFiles` tombstoned-body reap + GC; extend
  `clearStorage()`.
- `Pupa/Tests/PupaAppTests/TombstoneTests.swift` — new.
- `docs/architecture.md` — Persistence section: tombstones, the deletion
  lifecycle, tombstone-wins conflict rule, 180-day GC.
- `CHANGELOG.md` — patch bump; user-visible "deleting a MyApp now sticks across
  devices; sync no longer resurrects deleted apps."
- `Pupa/Sources/PupaApp/Version.swift` — bump `PupaAppVersion` (0.0.208 → 0.0.209).
- No AGUIKit change. `GuideSkills.version` unchanged (no user-facing guide copy).

## Out of scope

- Auto-merge / de-dup migration for existing twins — user prunes manually.
- Changing the UUID identity model — already correct.
- The redundant-creation path (seed/restoreExample by-name across not-yet-pulled
  devices) — an edge already mostly covered by provisioning (#199); tombstones
  don't address it and it's not the reported failure.

## Release note

0.0.208 is archived (build 1) but **not uploaded** — held pending this fix.
Re-archive after 0.0.209 lands, then upload both platforms.
