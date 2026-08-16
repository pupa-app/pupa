# AGUIKit

A small Swift Package that speaks the [AG-UI](https://github.com/ag-ui-protocol/ag-ui) protocol from the client side. It plays the same role as `@copilotkit/runtime` + `@copilotkit/react-core` do in the browser:

- Build `RunAgentInput` payloads with messages, tools, and context.
- POST them to an AG-UI server (e.g. a FastAPI app using `ag-ui-langgraph`).
- Stream and decode `text/event-stream` events as they arrive.
- Maintain a registry of locally-executable tools and run their handlers when the agent calls them.
- Drive the multi-round loop (round 1 → tool calls → round 2 with `ToolMessage` results → repeat).

It has no dependency on UIKit/AppKit/SwiftUI and no opinion on persistence — it's a transport + protocol layer. It's meant to be reusable outside the pupa project.

## Platforms

iOS 16+, macOS 13+, tvOS 16+, watchOS 9+. Swift 5.9.

## Usage

### 1. Define the tools the agent can call

```swift
import AGUIKit

let registry = ToolRegistry()

registry.register(ClientTool(
    descriptor: ToolDescriptor(
        name: "addItem",
        description: "Append an item to the list.",
        parameters: [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
        ]
    ),
    handler: { args in
        // args is AnyJSON; access via subscripts.
        let text = args["text"]?.stringValue ?? ""
        // …mutate your local state…
        return ["ok": true, "added": .string(text)]
    }
))
```

### 2. Open a session and send messages

```swift
let client = AgentClient(endpoint: URL(string: "http://localhost:8004/")!)
let session = AgentSession(
    client: client,
    registry: registry,
    threadId: UUID().uuidString
)

let stream = await session.send("add coffee to the list") {
    // Per-turn context (e.g. live state snapshots).
    [
        AgentContextEntry(
            description: "Live app state",
            value: #"{"items":[]}"#
        )
    ]
}

for try await event in stream {
    switch event {
    case .assistantMessageDelta(_, let delta):
        print(delta, terminator: "")
    case .assistantMessageEnd(_, let text):
        print("\n[final: \(text)]")
    case .toolCallExecuted(let name, _, let result):
        print("[tool \(name): \(result)]")
    case .toolCallUnhandled(let name, _):
        print("[unhandled tool \(name)]")
    case .completed:
        print("[done]")
    case .error(let msg, _):
        print("[error \(msg)]")
    default:
        break
    }
}
```

The session keeps the running message list internally. Subsequent `send()` calls continue the conversation.

## Wire format

`RunAgentInput` is encoded as camelCase JSON (matching the backend's Pydantic config with `alias_generator=to_camel`):

```json
{
  "threadId": "...",
  "runId": "...",
  "state": null,
  "messages": [...],
  "tools": [...],
  "context": [{"description": "...", "value": "..."}],
  "forwardedProps": {}
}
```

The response is `text/event-stream` with frames of the form `data: <event-json>\n\n`. Recognised event types: `RUN_STARTED`, `RUN_FINISHED`, `RUN_ERROR`, `TEXT_MESSAGE_*`, `TOOL_CALL_*`, `STATE_*`, `MESSAGES_SNAPSHOT`, `STEP_*`, `RAW`, `CUSTOM`. Unknown types are preserved as `.unknown(type:raw:)` rather than dropped.

## Build & test

```sh
cd AGUIKit
swift build
swift test
```

## What it doesn't do

- **Auth.** Pass any required headers via `AgentClient.extraHeaders` or by configuring the `URLSession`.
- **Optimistic UI / offline edits.** The session round-trips every change to the agent. If you want optimistic local mutations (the pupa canvas pattern), apply state changes synchronously in your tool handlers and let the round trip confirm.
- **Reasoning events.** `THINKING_*` and `REASONING_*` events arrive as `.unknown(...)` — implement them when needed.
- **State delta application** (RFC 6902 JSON Patch). `STATE_DELTA` is decoded as `AnyJSON` but not applied; feed it to your state store yourself.

## License

MIT — see [LICENSE](LICENSE). Deliberately more permissive than the rest
of the repo (MPL-2.0) so AGUIKit can be embedded anywhere, including in
closed-source apps.

Note for contributors: MIT code may be moved *into* the MPL-licensed
side of the repo freely, but MPL-licensed code may **not** be moved into
`AGUIKit/` — that would relicense it. Extract shared helpers from the app
into AGUIKit only if you wrote them or they were MIT to begin with.

Copyright © 2026 Pupa.
