import Foundation

/// Pure, store-free arithmetic expression engine for calculator formula
/// rows. Two responsibilities:
///
/// 1. **Parse + evaluate** an infix expression over a `[String: Double]`
///    variable environment. Supports `+ - * / % ^`, unary minus / plus,
///    parentheses, and the functions `min`, `max`, `abs`, `round`, `sqrt`,
///    `log` (natural), `exp`, `pow`. `^` is right-associative and binds
///    tighter than unary minus (`-2^2 == -4`).
/// 2. **Dependency ordering** — given each formula's referenced identifiers
///    (`referencedIdentifiers(in:)`), `topologicalSort` returns a safe
///    evaluation order or reports the keys caught in a cycle.
///
/// No SwiftUI, no store, no MainActor — fully unit-testable in isolation
/// and reused by `CalculatorResolver`.
public enum ExpressionEngine {

    // MARK: - Errors

    public enum EvalError: Error, Equatable, Sendable {
        case syntaxError(String)
        case unknownIdentifier(String)
        case unknownFunction(String)
        case arityMismatch(function: String)
        case divisionByZero
    }

    // MARK: - AST

    /// Parsed expression tree. Built once by `parse`, then reused for both
    /// `evaluate` and `identifiers` so a formula is tokenised a single time.
    public indirect enum Node: Equatable, Sendable {
        case number(Double)
        case identifier(String)
        case unary(op: Character, Node)
        case binary(op: Character, lhs: Node, rhs: Node)
        case call(name: String, args: [Node])
    }

    // MARK: - Public surface

    /// Parse `source` into an AST. Throws `EvalError.syntaxError` on a
    /// malformed expression (unbalanced parens, trailing operator, …).
    public static func parse(_ source: String) throws -> Node {
        var parser = Parser(source)
        let node = try parser.parseExpression()
        try parser.expectEnd()
        return node
    }

    /// Parse + evaluate `source` against `variables`. Convenience over
    /// `parse` + `evaluate(_:variables:)` for one-shot callers / tests.
    public static func evaluate(_ source: String, variables: [String: Double]) throws -> Double {
        let node = try parse(source)
        return try evaluate(node, variables: variables)
    }

    /// Evaluate a pre-parsed AST against `variables`.
    public static func evaluate(_ node: Node, variables: [String: Double]) throws -> Double {
        switch node {
        case .number(let v):
            return v
        case .identifier(let name):
            guard let v = variables[name] else { throw EvalError.unknownIdentifier(name) }
            return v
        case .unary(let op, let operand):
            let v = try evaluate(operand, variables: variables)
            return op == "-" ? -v : v
        case .binary(let op, let lhs, let rhs):
            let l = try evaluate(lhs, variables: variables)
            let r = try evaluate(rhs, variables: variables)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/":
                guard r != 0 else { throw EvalError.divisionByZero }
                return l / r
            case "%":
                guard r != 0 else { throw EvalError.divisionByZero }
                return l.truncatingRemainder(dividingBy: r)
            case "^": return pow(l, r)
            default: throw EvalError.syntaxError("unknown operator '\(op)'")
            }
        case .call(let name, let args):
            let values = try args.map { try evaluate($0, variables: variables) }
            return try applyFunction(name, values)
        }
    }

    /// Every bare identifier referenced by `node` (variables a formula
    /// depends on). Function names are NOT included. Used to build the
    /// dependency graph for `topologicalSort`.
    public static func identifiers(in node: Node) -> Set<String> {
        var found: Set<String> = []
        collectIdentifiers(node, into: &found)
        return found
    }

    /// Parse `source` and return its referenced identifiers, or throw if it
    /// doesn't parse. Convenience for the resolver's dependency pass.
    public static func referencedIdentifiers(in source: String) throws -> Set<String> {
        identifiers(in: try parse(source))
    }

    private static func collectIdentifiers(_ node: Node, into set: inout Set<String>) {
        switch node {
        case .number:
            break
        case .identifier(let name):
            set.insert(name)
        case .unary(_, let operand):
            collectIdentifiers(operand, into: &set)
        case .binary(_, let lhs, let rhs):
            collectIdentifiers(lhs, into: &set)
            collectIdentifiers(rhs, into: &set)
        case .call(_, let args):
            for arg in args { collectIdentifiers(arg, into: &set) }
        }
    }

    // MARK: - Functions

    private static func applyFunction(_ name: String, _ args: [Double]) throws -> Double {
        switch name {
        case "min", "max":
            guard !args.isEmpty else { throw EvalError.arityMismatch(function: name) }
            return name == "min" ? args.min()! : args.max()!
        case "abs":
            guard args.count == 1 else { throw EvalError.arityMismatch(function: name) }
            return Swift.abs(args[0])
        case "round":
            guard args.count == 1 else { throw EvalError.arityMismatch(function: name) }
            return args[0].rounded()
        case "sqrt":
            guard args.count == 1 else { throw EvalError.arityMismatch(function: name) }
            return sqrt(args[0])
        case "log":
            guard args.count == 1 else { throw EvalError.arityMismatch(function: name) }
            return Foundation.log(args[0])
        case "exp":
            guard args.count == 1 else { throw EvalError.arityMismatch(function: name) }
            return Foundation.exp(args[0])
        case "pow":
            guard args.count == 2 else { throw EvalError.arityMismatch(function: name) }
            return pow(args[0], args[1])
        default:
            throw EvalError.unknownFunction(name)
        }
    }

    // MARK: - Dependency topo-sort

    /// Result of ordering calc-row keys by their formula dependencies.
    public enum TopoResult: Equatable, Sendable {
        /// A safe evaluation order: every key appears after all the keys it
        /// depends on.
        case ordered([String])
        /// At least one dependency cycle exists. `cyclic` is every key that
        /// could not be ordered (the cycle members plus anything downstream
        /// of them, since those can't resolve either).
        case cycle(cyclic: Set<String>)
    }

    /// Kahn topological sort. `dependencies[key]` is the set of other keys
    /// `key` depends on (already intersected with the known key set by the
    /// caller — unknown identifiers are an evaluation concern, not an
    /// ordering one). Every key that should be ordered must appear as a key
    /// in `dependencies` (map to an empty set if it has no deps).
    public static func topologicalSort(dependencies: [String: Set<String>]) -> TopoResult {
        let allKeys = Set(dependencies.keys)
        // inDegree[k] = number of deps k still waits on.
        var inDegree: [String: Int] = [:]
        // dependents[d] = keys that depend on d (edges d -> dependent).
        var dependents: [String: [String]] = [:]
        for (key, deps) in dependencies {
            let realDeps = deps.intersection(allKeys)
            inDegree[key] = realDeps.count
            for dep in realDeps {
                dependents[dep, default: []].append(key)
            }
        }
        // Seed with everything that depends on nothing. Sort for a
        // deterministic order across runs.
        var queue = inDegree.filter { $0.value == 0 }.keys.sorted()
        var ordered: [String] = []
        while !queue.isEmpty {
            let key = queue.removeFirst()
            ordered.append(key)
            for dependent in (dependents[key] ?? []).sorted() {
                inDegree[dependent]! -= 1
                if inDegree[dependent] == 0 {
                    // Insert keeping the queue sorted for determinism.
                    let idx = queue.firstIndex(where: { $0 > dependent }) ?? queue.count
                    queue.insert(dependent, at: idx)
                }
            }
        }
        if ordered.count == allKeys.count {
            return .ordered(ordered)
        }
        // Anything not ordered is in (or downstream of) a cycle.
        return .cycle(cyclic: allKeys.subtracting(ordered))
    }

    // MARK: - Tokenizer + recursive-descent parser

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(Character)      // + - * / % ^
        case lparen
        case rparen
        case comma
    }

    private struct Parser {
        private let tokens: [Token]
        private var pos = 0

        init(_ source: String) {
            self.tokens = Parser.tokenize(source)
        }

        // expression := additive
        mutating func parseExpression() throws -> Node {
            try parseAdditive()
        }

        func expectEnd() throws {
            if pos != tokens.count {
                throw EvalError.syntaxError("unexpected trailing tokens")
            }
        }

        // additive := multiplicative (('+'|'-') multiplicative)*
        private mutating func parseAdditive() throws -> Node {
            var node = try parseMultiplicative()
            while case .op(let c)? = peek(), c == "+" || c == "-" {
                advance()
                let rhs = try parseMultiplicative()
                node = .binary(op: c, lhs: node, rhs: rhs)
            }
            return node
        }

        // multiplicative := unary (('*'|'/'|'%') unary)*
        private mutating func parseMultiplicative() throws -> Node {
            var node = try parseUnary()
            while case .op(let c)? = peek(), c == "*" || c == "/" || c == "%" {
                advance()
                let rhs = try parseUnary()
                node = .binary(op: c, lhs: node, rhs: rhs)
            }
            return node
        }

        // unary := ('-'|'+') unary | power
        private mutating func parseUnary() throws -> Node {
            if case .op(let c)? = peek(), c == "-" || c == "+" {
                advance()
                let operand = try parseUnary()
                return .unary(op: c, operand)
            }
            return try parsePower()
        }

        // power := primary ('^' unary)?    — right-associative; the right
        // operand is a unary so `2^-3` and `2^2^3` parse correctly.
        private mutating func parsePower() throws -> Node {
            let base = try parsePrimary()
            if case .op("^")? = peek() {
                advance()
                let exponent = try parseUnary()
                return .binary(op: "^", lhs: base, rhs: exponent)
            }
            return base
        }

        // primary := number | identifier | identifier '(' args ')' | '(' expression ')'
        private mutating func parsePrimary() throws -> Node {
            guard let token = peek() else {
                throw EvalError.syntaxError("unexpected end of expression")
            }
            switch token {
            case .number(let v):
                advance()
                return .number(v)
            case .identifier(let name):
                advance()
                if case .lparen? = peek() {
                    advance()
                    let args = try parseArguments()
                    try expect(.rparen)
                    return .call(name: name, args: args)
                }
                return .identifier(name)
            case .lparen:
                advance()
                let inner = try parseExpression()
                try expect(.rparen)
                return inner
            default:
                throw EvalError.syntaxError("unexpected token")
            }
        }

        // args := (expression (',' expression)*)?
        private mutating func parseArguments() throws -> [Node] {
            var args: [Node] = []
            if case .rparen? = peek() { return args }  // zero-arg call
            args.append(try parseExpression())
            while case .comma? = peek() {
                advance()
                args.append(try parseExpression())
            }
            return args
        }

        // MARK: token cursor

        private func peek() -> Token? {
            pos < tokens.count ? tokens[pos] : nil
        }

        private mutating func advance() {
            pos += 1
        }

        private mutating func expect(_ token: Token) throws {
            guard peek() == token else {
                throw EvalError.syntaxError("expected \(token)")
            }
            advance()
        }

        // MARK: lexer

        private static func tokenize(_ source: String) -> [Token] {
            var tokens: [Token] = []
            let chars = Array(source)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace {
                    i += 1
                    continue
                }
                if c.isNumber || c == "." {
                    var num = ""
                    while i < chars.count, chars[i].isNumber || chars[i] == "." {
                        num.append(chars[i])
                        i += 1
                    }
                    // A malformed number ("1.2.3") yields nil; emit it as 0
                    // and let evaluation proceed — the syntax check happens
                    // structurally elsewhere. Double() handles "1", "1.5",
                    // ".5", "1.".
                    tokens.append(.number(Double(num) ?? 0))
                    continue
                }
                if c.isLetter || c == "_" {
                    var ident = ""
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                        ident.append(chars[i])
                        i += 1
                    }
                    tokens.append(.identifier(ident))
                    continue
                }
                switch c {
                case "+", "-", "*", "/", "%", "^":
                    tokens.append(.op(c))
                case "(":
                    tokens.append(.lparen)
                case ")":
                    tokens.append(.rparen)
                case ",":
                    tokens.append(.comma)
                default:
                    // Skip unrecognised characters; the structural parser
                    // surfaces the resulting gap as a syntax error.
                    break
                }
                i += 1
            }
            return tokens
        }
    }
}
