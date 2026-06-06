import Foundation
import Testing
@testable import PupaApp

/// Tests for the pure arithmetic engine: operator precedence, right-assoc
/// `^`, unary minus vs power binding, the function table, error surfacing,
/// the mortgage payment formula, and the dependency topo-sort (diamond +
/// cycle detection).
@Suite("ExpressionEngine")
struct ExpressionEngineTests {

    private func eval(_ s: String, _ vars: [String: Double] = [:]) throws -> Double {
        try ExpressionEngine.evaluate(s, variables: vars)
    }

    // MARK: - Precedence + associativity

    @Test("multiplication binds tighter than addition")
    func precedence() throws {
        #expect(try eval("2 + 3 * 4") == 14)
        #expect(try eval("(2 + 3) * 4") == 20)
        #expect(try eval("10 - 2 - 3") == 5) // left-assoc
    }

    @Test("power is right-associative and binds tighter than unary minus")
    func powerAssoc() throws {
        #expect(try eval("2 ^ 3 ^ 2") == 512)   // 2^(3^2) = 2^9
        #expect(try eval("-2 ^ 2") == -4)        // -(2^2)
        #expect(try eval("2 ^ -2") == 0.25)      // 2^(-2)
    }

    @Test("modulo and unary plus")
    func moduloUnary() throws {
        #expect(try eval("10 % 3") == 1)
        #expect(try eval("+5 - -5") == 10)
    }

    @Test("decimal and parenthesised expressions")
    func decimals() throws {
        #expect(try eval("0.5 * 4") == 2)
        #expect(try eval("(1 + 1) * (3 - 1)") == 4)
    }

    // MARK: - Functions

    @Test("function table: min/max variadic, single-arg fns, pow")
    func functions() throws {
        #expect(try eval("min(3, 1, 2)") == 1)
        #expect(try eval("max(3, 1, 2)") == 3)
        #expect(try eval("abs(-7)") == 7)
        #expect(try eval("round(2.6)") == 3)
        #expect(try eval("sqrt(9)") == 3)
        #expect(try eval("pow(2, 10)") == 1024)
        #expect(abs(try eval("exp(0)") - 1) < 1e-9)
        #expect(abs(try eval("log(exp(1))") - 1) < 1e-9)
    }

    @Test("nested function calls and identifiers as args")
    func nestedCalls() throws {
        #expect(try eval("max(min(a, b), c)", ["a": 5, "b": 3, "c": 4]) == 4)
    }

    // MARK: - Errors

    @Test("unknown identifier throws")
    func unknownIdentifier() {
        #expect(throws: ExpressionEngine.EvalError.unknownIdentifier("x")) {
            try ExpressionEngine.evaluate("x + 1", variables: [:])
        }
    }

    @Test("unknown function throws")
    func unknownFunction() {
        #expect(throws: ExpressionEngine.EvalError.unknownFunction("frobnicate")) {
            try ExpressionEngine.evaluate("frobnicate(2)", variables: [:])
        }
    }

    @Test("division and modulo by zero throw")
    func divByZero() {
        #expect(throws: ExpressionEngine.EvalError.divisionByZero) {
            try ExpressionEngine.evaluate("1 / 0", variables: [:])
        }
        #expect(throws: ExpressionEngine.EvalError.divisionByZero) {
            try ExpressionEngine.evaluate("1 % 0", variables: [:])
        }
    }

    @Test("syntax errors throw rather than crash")
    func syntaxErrors() {
        #expect(throws: (any Error).self) { try ExpressionEngine.parse("2 +") }
        #expect(throws: (any Error).self) { try ExpressionEngine.parse("(1 + 2") }
        #expect(throws: (any Error).self) { try ExpressionEngine.parse("1 2 3") }
    }

    // MARK: - Mortgage formula

    @Test("mortgage monthly-payment formula parses and evaluates")
    func mortgage() throws {
        // M = P * r / (1 - (1+r)^(-n))
        let principal = 300_000.0
        let annualRate = 0.06
        let r = annualRate / 12.0      // monthly rate
        let n = 30.0 * 12.0            // payments
        let payment = try ExpressionEngine.evaluate(
            "principal * r / (1 - (1+r)^(-n))",
            variables: ["principal": principal, "r": r, "n": n]
        )
        // Independent reference computation.
        let expected = principal * r / (1 - pow(1 + r, -n))
        #expect(abs(payment - expected) < 1e-6)
        #expect(payment > 1797 && payment < 1799) // ~$1798.65
    }

    // MARK: - Identifier extraction

    @Test("referencedIdentifiers excludes function names")
    func identifierExtraction() throws {
        let ids = try ExpressionEngine.referencedIdentifiers(in: "max(a, b) + c * 2")
        #expect(ids == ["a", "b", "c"])
    }

    // MARK: - Topological sort

    @Test("topo-sort orders dependencies before dependents (diamond)")
    func topoDiamond() {
        // a -> b, a -> c, b -> d, c -> d  (d depends on b & c; b & c depend on a)
        let deps: [String: Set<String>] = [
            "a": [],
            "b": ["a"],
            "c": ["a"],
            "d": ["b", "c"],
        ]
        guard case .ordered(let order) = ExpressionEngine.topologicalSort(dependencies: deps) else {
            Issue.record("expected ordered, got cycle")
            return
        }
        func idx(_ k: String) -> Int { order.firstIndex(of: k)! }
        #expect(idx("a") < idx("b"))
        #expect(idx("a") < idx("c"))
        #expect(idx("b") < idx("d"))
        #expect(idx("c") < idx("d"))
        #expect(order.count == 4)
    }

    @Test("topo-sort detects a cycle and reports its members")
    func topoCycle() {
        let deps: [String: Set<String>] = [
            "x": ["y"],
            "y": ["x"],
            "z": [],
        ]
        guard case .cycle(let cyclic) = ExpressionEngine.topologicalSort(dependencies: deps) else {
            Issue.record("expected cycle")
            return
        }
        #expect(cyclic.contains("x"))
        #expect(cyclic.contains("y"))
        #expect(!cyclic.contains("z")) // z is acyclic
    }

    @Test("self-reference is a cycle")
    func selfCycle() {
        let deps: [String: Set<String>] = ["a": ["a"]]
        #expect(ExpressionEngine.topologicalSort(dependencies: deps) == .cycle(cyclic: ["a"]))
    }
}
