import Foundation
import Testing
@testable import AGUIKit

@Suite("AnyJSON")
struct AnyJSONTests {
    @Test func roundTripObject() throws {
        let json: AnyJSON = [
            "name": "jeans",
            "size": "M",
            "tags": ["bottoms", "denim"],
            "year": 2024,
            "price": 39.99,
            "outOfStock": false,
            "discount": nil,
        ]
        let data = try JSONEncoder().encode(json)
        let back = try JSONDecoder().decode(AnyJSON.self, from: data)
        #expect(json == back)
    }

    @Test func intStaysInt_doubleStaysDouble() throws {
        let raw = #"{"a": 1, "b": 2.5}"#.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(AnyJSON.self, from: raw)
        #expect(parsed["a"] == .int(1))
        #expect(parsed["b"] == .double(2.5))
    }

    @Test func subscriptAccessors() {
        let j: AnyJSON = ["nested": ["x": 1, "y": 2]]
        #expect(j["nested"]?["x"]?.intValue == 1)
        #expect(j["missing"] == nil)
        let arr: AnyJSON = [1, 2, 3]
        #expect(arr[1]?.intValue == 2)
        #expect(arr[99] == nil)
    }

    @Test func encodeNullExplicitly() throws {
        let j: AnyJSON = ["x": nil]
        let s = String(data: try JSONEncoder().encode(j), encoding: .utf8) ?? ""
        #expect(s == #"{"x":null}"#)
    }
}
