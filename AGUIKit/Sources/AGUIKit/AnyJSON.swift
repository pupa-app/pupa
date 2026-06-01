import Foundation

/// A `Codable` representation of an arbitrary JSON value.
///
/// Used wherever the AG-UI protocol leaves a value's shape open: tool parameters
/// (JSON Schema), context payloads, tool arguments, tool results, raw events.
/// Values are dictionary-keyed (objects), array-indexed, or one of the JSON
/// scalars.
public enum AnyJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])
}

// MARK: - Convenience accessors

public extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d: return Int(d)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var arrayValue: [AnyJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var objectValue: [String: AnyJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
    subscript(key: String) -> AnyJSON? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }
    subscript(index: Int) -> AnyJSON? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

// MARK: - Codable

extension AnyJSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        // Try Int first; only fall back to Double for fractional values. JSONDecoder
        // happily decodes 1.0 into Int, which we don't want for round-tripping
        // semantics — so we go through NSNumber to detect fractional content.
        if let n = try? c.decode(Double.self) {
            if n.truncatingRemainder(dividingBy: 1) == 0 && n >= Double(Int.min) && n <= Double(Int.max) {
                self = .int(Int(n))
            } else {
                self = .double(n)
            }
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? c.decode([AnyJSON].self) {
            self = .array(a)
            return
        }
        if let o = try? c.decode([String: AnyJSON].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Value is not a JSON-encodable type"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - ExpressibleBy literals (for ergonomic test/data construction)

extension AnyJSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension AnyJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension AnyJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension AnyJSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension AnyJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension AnyJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyJSON...) { self = .array(elements) }
}
extension AnyJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyJSON)...) {
        var dict: [String: AnyJSON] = [:]
        for (k, v) in elements { dict[k] = v }
        self = .object(dict)
    }
}
