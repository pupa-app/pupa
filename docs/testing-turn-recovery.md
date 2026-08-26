# Testing turn recovery by hand

Playbook for an agent driving a **running** Pupa build, for the one area the
suite can't reach: a turn parked on a frontend tool, interrupted for real
(pupa#258). Unit tests pin the wire and the state machine; everything here needs
a real process, a real socket, or a real clock.

Read [architecture.md](architecture.md) § "Resuming a turn parked on a frontend
tool" first — it is the spec these scenarios check. For the layers that *are*
automatable — headless whole-turn scenarios and `PupaCtl` against a live
backend — see [testing.md](testing.md).

**Several scenarios below are now automated.** `TurnRecoveryUITests`
(`make ui-test-recovery`) drives a real simulator process through
background/foreground, a kill mid-stream, and a kill inside the park window —
the last made sittable rather than raced by the scripted `fail: "hang"`. What
stays here is what it still cannot reach: a *real* backend park with real
timers, a real network drop, real jetsam, and the multi-park and expired-park
endings. Note also that the simulator never suspends a backgrounded app, so its
~30s grace never fires there — only a device tells you the truth about that.

## On a real device

The simulator cannot reach the case that matters most: it never suspends a
backgrounded app, so the `beginBackgroundTask` grace never expires, sockets stay
alive, and jetsam never happens. Everything the suite covers passes there —
including a backgrounded-then-killed relaunch — so a turn still lost in real use
is a device-only path.

Diagnostics are off in a release build. Settings → Profile → **Diagnostic
logging** turns them on live, no relaunch, and every line goes to the unified
log, which survives the app being suspended, killed, or relaunched:

```sh
# The phone must be on USB — `log` cannot reach a Wi-Fi-paired device, and
# `collect` fails "Device not configured (6)". Needs root; `log stream` has
# no device option at all on macOS 26.
sudo log collect --device-udid <udid> --last 2h --output build/device.logarchive
log show build/device.logarchive --predicate 'subsystem BEGINSWITH "dev.pupa"' \
  --style compact > build/trace.log
```

`xcrun devicectl list devices` prints the udid. (It also prints an app
version, but that is the project's stale `MARKETING_VERSION` — synced only at
release — so it cannot tell you which branch is installed. Settings ▸ Profile ▸
Version reads `PupaAppVersion` and can.)

These lines log at `.default` so they persist to disk. `.info` would survive a
live `log stream` and be gone by the time anyone collected an archive. Console.app with the phone
selected and `dev.pupa` in the filter is the same thing by hand. Two categories:
`session` is the round-by-round narrative, `probe` is one line of turn state per
change — the same JSON the UI suite asserts on, so a trace from the field lines
up with what the tests check.

What to look for, in order: `send() user=` (the turn started), `round N → POST`,
`stream dropped … reattach N/4` (the retry ladder ran), `reattach tail empty`
(the resume never landed), `foreground reattach: thread=`, `rewound replay
cursor`, and how it ends — `settled → completed(produced)` versus
`completed(silent(…))`. In the probe line, `tif` staying 1 across a relaunch and
`pd` staying non-nil are the two tells that recovery never completed.

Messages are not logged — only their length. Turn diagnostics back off
afterwards: the lines are public in the device log.

## The mechanism in one paragraph

The backend closes its SSE and **parks** while the app runs an on-device tool.
Nothing is in flight during that window, so an interruption there loses the turn
unless two records survive: the **rewind point** (`pendingDispatchAfterSeq` in
the transcript snapshot — the replay cursor that re-delivers the `on_interrupt`
frame) and the **journal** (`dispatch/<threadId>.json` — what each call did).
Recovery rewinds, the backend re-sends the call list, and the journal answers it
without re-running side effects.

## Setup

```sh
make mac-demo                 # backend must be on :8004
```

Logs go to **stderr** with grep-stable prefixes (`[AGUIKit ses]`, `[AGUIKit clt]`),
on by default in debug. Force with `AGUIKIT_LOG=1`. Pipe them: `make mac-demo 2>&1 | tee /tmp/pupa.log`.

Shrink the clocks — the defaults make manual testing unbearable. Set on the
**backend** process:

| Env | Default | Use |
|---|---|---|
| `PUPA_FRONTEND_WAIT_TIMEOUT` | 300s | park wall — drop to `20` to test expiry |
| `PUPA_FRONTEND_LIVENESS_GRACE` | 30s | grace after last keepalive |
| `PUPA_SSE_REPLAY_TTL` | 21600s (6h) | replay log retention; `0` **disables replay** (use to test the unstamped-backend path) |

Effective park deadline is `min(wall, last_keepalive + grace)` unless the client
reported itself backgrounded. The client pings `command.keepalive` every ~10s
while a dispatch is in flight.

### Files to watch

```sh
ROOT=~/Library/Application\ Support/pupa
ls "$ROOT/dispatch/"                       # journals, one per thread
cat "$ROOT/dispatch/<threadId>.json"       # per-call: name, result, finished
cat "$ROOT/state/transcripts/<threadId>.json" | jq '.turnInFlight, .lastEventSeq, .pendingDispatchAfterSeq'
```

`turnInFlight: true` with no live stream is the tell for most regressions here.

### Log lines that mark each step

```
round N paused on interrupt → dispatching K frontend tool(s)   park
dispatch tool=… call=…                                          handler ran
replay tool=… from journal                                      handler skipped, result reused
round N+1 → POST … resume=true                                  resume going out
reattach tail empty — the resume never landed, re-POSTing it    log probe said nothing
rewound replay cursor thread=… after_seq=N                      rewind engaged
reattach: nothing buffered … → completed                        empty tail
```

## What to make it park on

Any frontend tool: ask for something that writes a component
(`addComponent`, `addTrackerItems`), a memory write, or a calendar write. Prefer
a **side-effecting** one — the whole point is proving it doesn't run twice.
Multi-step asks ("add three items, then read them back") produce a turn that
parks **more than once**, which is its own scenario below.

## Scenarios

Each: **do** → **expect** → **regression looks like**.

### 1. App killed mid-dispatch

Kill the app (⌘Q won't do — force-quit / stop the process) while a tool is
running, then relaunch and open the same chat.

- Expect: the turn resumes, the reply arrives, the side effect appears **once**.
  Log shows `rewound replay cursor` then `replay tool=… from journal`.
- Regression: side effect applied twice; or the chat sits idle and your next
  message starts a fresh turn.

Hardest to time. Make the tool slow if you can (a big write, or a memory op on a
large store), or use the shell-approval interrupt to hold the turn open.

### 2. Network dropped mid-resume, app stays alive

Turn Wi-Fi off just as the tool finishes; turn it back on and foreground the app.

- Expect: `foreground reattach` rewinds to the interrupt (`after_seq` = the
  parked value, **not** the live cursor), the turn completes, no double apply.
- Regression: reattach POSTs the live cursor, tail is empty, turn silently
  declared settled — this was the bug; it is the one path the mocks could only
  half-stage.

### 3. Turn parks twice

Ask for something needing two rounds of on-device work. Kill or drop the network
during the **second** dispatch.

- Expect: recoverable exactly like the first. Snapshot's
  `pendingDispatchAfterSeq` should hold the **second** park's seq while it runs.
- Regression: `pendingDispatchAfterSeq` is `null` during the second dispatch →
  nothing to rewind to, turn lost.

### 4. Park expires

Set `PUPA_FRONTEND_WAIT_TIMEOUT=20`, park a turn, leave the app away past it,
come back.

- Expect: a system bubble — "that turn was interrupted … timed out". Journal
  file **gone**, `pendingDispatchAfterSeq` cleared, snapshot no longer
  `turnInFlight`.
- Regression: a generic "the assistant ran into a problem" banner instead, and
  the same error again on every relaunch.

Note the replay log outlives the park, so an expired park still *replays* its
interrupt — the resume is what gets rejected. That asymmetry is the point of
this case.

### 5. Reply finished, response lost

Hardest to stage: needs the resume to arrive while its response doesn't. A proxy
that accepts and drops, or killing the tunnel between POST and first byte.

- Expect: the client probes the replay log first and **recovers the finished
  reply**. No error bubble.
- Regression: "the assistant ran into a problem" while the reply sits in the
  backend's log — strictly worse than a plain drop.

### 6. Backend with replay disabled

`PUPA_SSE_REPLAY_TTL=0`, then park a turn and drop the connection.

- Expect: the client re-POSTs the resume; it **never** sends
  `command.reattach` (that POST would land on a real agent loop with an empty
  message list and retire the parked session).
- Check: `grep 'reattach' /tmp/pupa.log` should show no reattach POSTs for the
  thread.

### 7. Gated tools during recovery

Have the agent unlock a tool group (`get_tools_<kind>`) earlier in the thread,
then park and recover.

- Expect: no "the tools you activated are now available" turn out of nowhere,
  no visible latency spike from a cold prompt cache.
- Regression: either of those — the recovery advertised the wrong tool surface.

Relaunch resets the in-memory gate state, so recovery after a **kill** advertises
the narrow surface. That's benign (the backend's live client surface is frozen,
and its unlock check is a set difference) but it's the thing to re-check if
unlock behaviour ever changes.

### 8. Two clients on one thread

Same thread open on two devices/instances; send on one, then reconnect the other
mid-turn.

- Expect: the newer request takes the stream over whole; the older stops. The
  thread's persisted transcript reads in order.
- Regression: the reply split across the two, or the transcript out of order.

Backend-side fix — see pupa-backend `registry.attach`.

## Things that are NOT bugs

- A **transport failure or Stop** mid-recovery keeps the rewind point and the
  journal on purpose. Neither says anything about whether the park is alive.
- An **empty reattach tail** does not reap the journal — the reattach may simply
  have started past the interrupt with the backend still parked.
- An **unstamped** interrupt frame (backend predating the replay layer) yields no
  rewind point at all and degrades to the old restart behaviour.

## Reporting back

For anything that reproduces, capture: the log slice around
`paused on interrupt`, the journal JSON, the snapshot's three fields above, and
whether the side effect landed zero / once / twice. That's enough to place the
failure in the state machine without a re-run.
