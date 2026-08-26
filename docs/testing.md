# Testing & debugging

Four layers. Each catches something the one below it can't.

| Layer | Runs | Catches | Cost |
|---|---|---|---|
| Unit suites (`make test`) | SwiftPM, headless | logic, state machines, wire encoding | seconds |
| Scenario harness (`PupaHarness`) | SwiftPM, headless | whole turns: chat → tool → canvas → disk | ms per turn |
| `PupaCtl` | shell | the same, against a **live** backend | one turn |
| XCUITest (`PupaHost`) | simulator | views, navigation, gestures, **background / kill / relaunch** | minutes |

For what none of them reach — real kills, real dropped sockets, real clocks —
see [testing-turn-recovery.md](testing-turn-recovery.md).

## Driving the app as an agent

`PupaCtl` sends chat turns through the real object graph — the same
`ChatSessionCoordinator`, the same registered tools, the same stores — and
prints what they touched. No window, no simulator, no Xcode.

```sh
make ctl ARGS='chat "add a tracker called Water Intake"'
make ctl ARGS='repl'                       # keep talking
make ctl ARGS='dump'                       # state between turns
make ctl ARGS='help'
```

State lives under `--root` (default `~/.pupa-ctl`) and **persists across
invocations**, so consecutive calls continue the same conversation. History is
rehydrated the way the app does it, so turn three sees what turns one and two
wrote. `--new-session` starts over.

```sh
make ctl ARGS='chat "add three entries for this week" --root /tmp/dbg'
make ctl ARGS='chat "now show me the total" --root /tmp/dbg'
```

A report covers all four surfaces a turn touches:

```
── chat ──      bubbles, and every tool that ran with its args and result
── canvas ──    components, active one, agent-written summaries
── recovery ──  turnInFlight / lastEventSeq / pendingDispatchAfterSeq, journal
── wire ──      per round: message count, tools offered, last user message
```

`--json` gives the same thing machine-readable. `--quiet` drops the AGUIKit
stream logs; `--no-wire` drops the last section.

### Live backends need a token

The backend answers 401 unpaired. Mint a code on the backend (`make pair` in
`pupa-backend`), then:

```sh
make ctl ARGS='pair ABC123'                # prints the token
export PUPA_CTL_TOKEN=…
```

The token is held in memory for the run — never written to the Keychain, so
driving a backend can't disturb the real app's pairing.

## Scripted backends

A script is a `.jsonl`: one round per line, `events` holding raw AG-UI events.
Rounds are served in file order; an explicit `"round": 2` pins one. Hand-written
fixtures may spread a round over several lines — lines accumulate until they
parse — and `//` comments are skipped.

```sh
make ctl ARGS='replay Pupa/Fixtures/add-tracker.jsonl --send "add a Books tracker"'
```

Failure injection, for the paths a happy stream can't reach:

```json
{"fail":"connect","events":[]}
{"fail":"midStream","failAfter":3,"events":[…]}
{"fail":"hang","holdMillis":2000,"events":[…]}
```

`hang` accepts the POST, delivers its events, and answers nothing more — the app
sits exactly where the round left it with no clock of its own. It is what makes
"killed while parked on a frontend tool" a state a test can sit in rather than a
race against the backend's timers. Omit `holdMillis` to hold until the session
times out.

### Record, don't guess

Hand-written fixtures drift from the backend. Record one instead — the turn runs
for real and the SSE is teed into a replayable script:

```sh
make ctl ARGS='record /tmp/live.jsonl --send "add a tracker"'
make ctl ARGS='replay /tmp/live.jsonl --send "add a tracker"'
```

`--harness claude_code` records against a specific backend harness rather than
the default one; `--trim BYTES` (default 4096) caps text deltas and empties
replayed state so the result fits in a UI test's launch environment, where
arguments and environment share one ~1MB budget. Trimming never drops a frame —
that would shift every replay seq, which is what recovery keys off.

`make record-fixture NAME=… PROMPT=…` does the same into
`PupaHost/PupaHostUITests/Fixtures/`, and refuses to bank a recording with no
`on_interrupt` in it: a turn that never parked can't exercise turn recovery.

## Driving the launched app

The app accepts launch arguments so a UI test can drive it with no network and
no pairing. All of them are ignored without `-PupaStorageRoot` — nothing here
may run against real app data.

| Argument | Effect |
|---|---|
| `-PupaStorageRoot PATH` | isolate storage; `ephemeral` picks a fresh dir in the app's own temp, `ephemeral:NAME` the **same** dir every launch |
| `-PupaStorageReset 1` | wipe that dir first — launch 1 of a case, not the relaunch |
| `-PupaBackendURL URL` | point the agent somewhere |
| `-PupaHarness ID` | pick the backend agent harness (`claude_code`, `deepagents`) |
| `-PupaBackendToken TOK` | reach a paired backend without the Keychain (or `PUPA_BACKEND_TOKEN`) |
| `-PupaScript PATH` | serve a canned backend |
| `-PupaSkipOnboarding 1` | skip first-run |
| `-PupaBackgroundGrace S` | release the iOS stream keep-alive after S seconds |
| `-PupaReattachAttempts N` / `-PupaReattachDelayMs MS` | shrink the dropped-stream retry budget |

`ephemeral:NAME` is what lets a test kill the app and relaunch onto the state it
left behind — bare `ephemeral` is a new dir every launch. The clock flags exist
because **the simulator does not enforce the ~30s background grace**: a
backgrounded simulator app is never suspended, its sockets stay alive, and the
expiry handler never fires. So waiting proves nothing. Drive the three levers
separately instead — `press(.home)`/`activate()` for the scene-phase path, a
fixture's `midStream` for the socket death, `-PupaBackgroundGrace` for expiry.

`PUPA_SCRIPT` in the environment carries a script inline instead of by path —
the only form that crosses the sandbox boundary between a UI test runner and the
app it launches. `ephemeral` exists for the same reason.

```sh
make ui-test                      # SIM='iPhone 17' device, UITEST='…' to scope
make ui-test-recovery             # the recovery suite + build/trace.log
export PUPA_BACKEND_TOKEN=$(…)    # make ctl ARGS='pair <CODE>' prints one
make ui-test-live                 # the same, plus two cases against a real backend
```

`ui-test-live` adds two cases that open a real socket to `--harness claude_code`
on `:8004` — a live turn crossing background/foreground, and one killed and
relaunched. They assert structurally (settles, no banner, every park answered),
never on wording: a live model writes what it likes. Without a token they skip,
so `make ui-test` runs the whole suite offline.

Its config reaches the runner through the runner's **bundle**
(`Fixtures/live-backend.json`, written before the build and deleted after —
it holds a device token, and is gitignored). Neither documented environment
channel survives to a UI-test runner: `TEST_RUNNER_<VAR>` build settings inject
into a test *host*, which a UI test doesn't have, and xcscheme environment
values are not build-setting-expanded under `xcodebuild` — `$(PUPA_BACKEND)`
reached the app as that literal string and the POST failed `unsupported URL`.
Both were diagnosed from `build/trace.log`, which is what it is for.

`TurnRecoveryUITests` covers what only a launched app can prove: a live turn
left alone across background/foreground, a socket that dies while away, a kill
mid-stream, a kill inside the frontend-tool park window, and the two ways a
stopped turn can end.

It reads state from the `debug.turnState` probe — one always-mounted element
whose accessibility *value* carries the whole turn state as compact JSON
(`isStreaming`, `connectionIssue`, `pendingDispatchAfterSeq`, the notice reason,
a ring of recent event kinds…). The runner and the app don't share a sandbox, so
a trace file is unreachable; this is the channel. It reports nothing while the
app is backgrounded — there is no accessibility tree then — so `ui-test-recovery`
also captures the app's unified log (`dev.pupa.aguikit`) to `build/trace.log`,
which is the only thing that keeps reporting across that window.

The drawer covers the bottom bar with a bar of its own and its open state
persists, so a UI test that needs the bottom bar passes `-pupa.ui.sidebarOpen
NO`, and one that needs the drawer's own surfaces passes `YES`. `isHittable` is
no guard here: XCUITest reports the covered toggle as hittable.

Screenshots land in `build/shots`; the suites attach one on failure.
Query by identifier (`PupaID` in PupaApp, mirrored in the test target), not by
label — labels are user-facing copy and change with the wording. Keep this layer
to what genuinely needs pixels; everything below the view layer is covered far
faster by the scenario harness.

## In tests

`Scenario` is the same thing from Swift. See
[ScenarioHarnessTests.swift](../Pupa/Tests/PupaAppTests/ScenarioHarnessTests.swift).

```swift
ScriptedTransport.script = try Script.parse(script)
let scenario = Scenario(root: root, backend: url, urlSession: ScriptedTransport.session())
defer { scenario.restoreStorageRoot() }
await scenario.send("add a Books tracker")
#expect(scenario.report().toolCalls.map(\.name) == ["addComponent"])
```

Two rules:

- `PupaStorage.overrideRoot` is process-global. Restore it (`restoreStorageRoot`)
  or later suites write into your root. Suites sharing the transport statics
  must be `.serialized`.
- The on-disk records (`recovery`, `journal`) are written by a detached task
  after settle, so they lag the in-memory turn. Assert on them via
  `waitForReport(where:)`, never a single sample.
