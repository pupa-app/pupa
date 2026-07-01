import Foundation
import Testing
@testable import AGUIKit

/// Round-trip + minimality tests for the snapshot diff engine.
/// Core invariant: `apply(diff(a, b), to: a) == b` for any pair.
struct JSONDiffTests {

    /// Assert the round-trip holds; return the patch for extra checks.
    @discardableResult
    private func roundTrip(_ a: AnyJSON, _ b: AnyJSON) -> JSONPatch? {
        let patch = JSONDiff.diff(a, b)
        let result = patch.map { JSONDiff.apply($0, to: a) } ?? a
        #expect(result == b)
        return patch
    }

    @Test func identicalYieldsNilPatch() {
        let v: AnyJSON = ["a": 1, "b": ["x", "y"]]
        #expect(JSONDiff.diff(v, v) == nil)
    }

    @Test func scalarChange() { roundTrip(1, 2) }
    @Test func typeChange() { roundTrip(.string("1"), .int(1)) }
    @Test func nullTransitions() {
        roundTrip(.null, .string("x"))
        roundTrip(.string("x"), .null)
    }

    @Test func objectSetRemoveAdd() {
        let a: AnyJSON = ["keep": 1, "drop": 2, "change": "old"]
        let b: AnyJSON = ["keep": 1, "change": "new", "add": true]
        let patch = roundTrip(a, b)
        guard case .object(let set, let remove) = patch else {
            Issue.record("expected object patch"); return
        }
        // `keep` unchanged → not in set. drop → removed. change + add → set.
        #expect(set["keep"] == nil)
        #expect(remove == ["drop"])
        #expect(set["change"] != nil)
        #expect(set["add"] != nil)
    }

    @Test func nestedObject() {
        let a: AnyJSON = ["outer": ["inner": 1, "same": "z"]]
        let b: AnyJSON = ["outer": ["inner": 2, "same": "z"]]
        roundTrip(a, b)
    }

    @Test func arrayAppendIsMinimal() {
        let a: AnyJSON = .array([1, 2, 3])
        let b: AnyJSON = .array([1, 2, 3, 4])
        let patch = roundTrip(a, b)
        // Expect keep(3) + insert([4]) — not a wholesale replace.
        guard case .array(let ops) = patch else {
            Issue.record("expected array patch"); return
        }
        #expect(ops.count == 2)
        #expect(ops.first == .keep(3))
        #expect(ops.last == .insert([4]))
    }

    @Test func arrayRemoveMiddle() {
        roundTrip(.array([1, 2, 3, 4]), .array([1, 2, 4]))
    }

    @Test func arrayReorder() {
        roundTrip(.array(["a", "b", "c"]), .array(["c", "a", "b"]))
    }

    @Test func arrayOfObjectsEditOne() {
        let a: AnyJSON = .array([
            ["id": "1", "v": "x"],
            ["id": "2", "v": "y"],
            ["id": "3", "v": "z"],
        ])
        let b: AnyJSON = .array([
            ["id": "1", "v": "x"],
            ["id": "2", "v": "CHANGED"],
            ["id": "3", "v": "z"],
        ])
        roundTrip(a, b)
    }

    @Test func emptyTransitions() {
        roundTrip(.array([]), .array([1, 2]))
        roundTrip(.array([1, 2]), .array([]))
        roundTrip(.object([:]), ["a": 1])
    }

    @Test func patchIsCodable() throws {
        let a: AnyJSON = ["rows": .array([["v": 1]]), "title": "old"]
        let b: AnyJSON = ["rows": .array([["v": 1], ["v": 2]]), "title": "new"]
        let patch = JSONDiff.diff(a, b)!
        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(JSONPatch.self, from: data)
        #expect(JSONDiff.apply(decoded, to: a) == b)
    }

    @Test func deepNestedMixed() {
        let a: AnyJSON = [
            "app": [
                "components": .array([
                    ["kind": "tracker", "items": .array([["f": "1"]])],
                ]),
                "meta": ["locked": false],
            ],
        ]
        let b: AnyJSON = [
            "app": [
                "components": .array([
                    ["kind": "tracker", "items": .array([["f": "1"], ["f": "2"]])],
                ]),
                "meta": ["locked": true],
            ],
        ]
        roundTrip(a, b)
    }
}
