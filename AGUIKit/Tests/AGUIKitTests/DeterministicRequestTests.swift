import Foundation
import Testing
@testable import AGUIKit

/// The provider caches an exact prompt prefix, so a request that differs only
/// in key order is a cache miss that costs a full re-write. Swift `Dictionary`
/// iteration order is randomised, so nothing here is stable by accident.
@Suite("Deterministic request bytes")
struct DeterministicRequestTests {

    // MARK: - AgentContextEntry(encoding:)

    @Test func encodingInitSortsKeys() throws {
        let entry = AgentContextEntry(
            description: "myApp type",
            encoding: ["typeId": "tracker", "myAppName": "WebExplorer"]
        )
        #expect(entry.value == #"{"myAppName":"WebExplorer","typeId":"tracker"}"#)
    }

    @Test func encodingInitIsStableAcrossManyEncodes() throws {
        // A single encode can look fine by luck; the randomised order shows up
        // across repeats within a process.
        let payload = [
            "name": "check-booking",
            "description": "Poll each Watching booking row's URL.",
            "when_to_use": "when the booking-watch cron fires",
            "argument_hint": "none",
        ]
        let values = Set((0..<50).map {
            AgentContextEntry(description: "skill \($0)", encoding: payload).value
        })
        #expect(values.count == 1)
    }

    @Test func nestedObjectsInsideArraysAreSortedToo() throws {
        let roster = ["skills": [["when_to_use": "w", "name": "n", "description": "d"]]]
        let entry = AgentContextEntry(description: "Skills", encoding: roster)
        #expect(entry.value == #"{"skills":[{"description":"d","name":"n","when_to_use":"w"}]}"#)
    }

    @Test func encodingInitFallsBackWhenEncodingFails() throws {
        struct Explodes: Encodable {
            func encode(to encoder: Encoder) throws {
                throw EncodingError.invalidValue(
                    self, .init(codingPath: [], debugDescription: "nope")
                )
            }
        }
        let entry = AgentContextEntry(
            description: "d", encoding: Explodes(), fallback: #"{"paths":[]}"#
        )
        #expect(entry.value == #"{"paths":[]}"#)
    }

    @Test func plainValueInitIsUntouched() throws {
        // The verbatim initialiser must not reformat — callers pass
        // already-canonical JSON (e.g. CanvasSummary) through it.
        let raw = #"{"z":1,"a":2}"#
        #expect(AgentContextEntry(description: "d", value: raw).value == raw)
    }

    // MARK: - The request body

    @Test func toolSchemaKeyOrderIsStableOnTheWire() throws {
        // Tool schemas sit at the very front of the cache prefix, so a
        // reshuffle here invalidates everything behind it.
        let schema: AnyJSON = [
            "type": "object",
            "properties": [
                "componentId": ["type": "string"],
                "name": ["type": "string"],
                "summary": ["type": "string"],
            ],
            "required": ["componentId"],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodies = Set(try (0..<50).map { _ in
            String(decoding: try encoder.encode(schema), as: UTF8.self)
        })
        #expect(bodies.count == 1)
        #expect(bodies.first?.contains(#""properties":{"componentId""#) == true)
    }
}
