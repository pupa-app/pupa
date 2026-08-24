# Testing & debugging

Four layers. Each catches something the one below it can't.

| Layer | Runs | Catches | Cost |
|---|---|---|---|
| Unit suites (`make test`) | SwiftPM, headless | logic, state machines, wire encoding | seconds |
| Scenario harness (`PupaHarness`) | SwiftPM, headless | whole turns: chat → tool → canvas → disk | ms per turn |
| `PupaCtl` | shell | the same, against a **live** backend | one turn |
| XCUITest (`PupaHost`) | simulator | views, navigation, gestures | minutes |

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
```

### Record, don't guess

Hand-written fixtures drift from the backend. Record one instead — the turn runs
for real and the SSE is teed into a replayable script:

```sh
make ctl ARGS='record /tmp/live.jsonl --send "add a tracker"'
make ctl ARGS='replay /tmp/live.jsonl --send "add a tracker"'
```

## Driving the launched app

The app accepts launch arguments so a UI test can drive it with no network and
no pairing. All of them are ignored without `-PupaStorageRoot` — nothing here
may run against real app data.

| Argument | Effect |
|---|---|
| `-PupaStorageRoot PATH` | isolate storage; `ephemeral` picks a fresh dir in the app's own temp |
| `-PupaBackendURL URL` | point the agent somewhere |
| `-PupaScript PATH` | serve a canned backend |
| `-PupaSkipOnboarding 1` | skip first-run |

`PUPA_SCRIPT` in the environment carries a script inline instead of by path —
the only form that crosses the sandbox boundary between a UI test runner and the
app it launches. `ephemeral` exists for the same reason.

```sh
make ui-test                      # SIM='iPhone 17' to pick a device
```

Screenshots land in `build/shots`; `ChatFlowUITests` attaches one on failure.
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
