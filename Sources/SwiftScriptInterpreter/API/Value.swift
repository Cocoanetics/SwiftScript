import SwiftSyntax
import Foundation

/// `@unchecked Sendable`: `Value` carries `Function` (closures), `Any`
/// (opaque host values), and class instances — none of which Swift can
/// prove Sendable. The conformance is here so script values can flow
/// through async / nonisolated host code without forcing every caller
/// to wrap in detached tasks. Like `Interpreter`'s same conformance,
/// the contract is "one logical owner at a time": a single script is
/// single-threaded, and concurrency inside it routes through the same
/// `Interpreter`.
public indirect enum Value: @unchecked Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case void
    case function(Function)
    case range(lower: Int, upper: Int, closed: Bool)
    case array([Value])
    case optional(Value?)
    /// Tuple value, optionally labeled. Labels are an array parallel to
    /// the elements; entries are `nil` for unlabeled positions. Empty
    /// labels (or a count-mismatched labels array) means "no labels".
    case tuple([Value], labels: [String?])
    /// Dictionary, stored as an array of key/value pairs in insertion
    /// order. Lookup is linear — fine for the small dicts LLMs tend to
    /// produce; a real Hashable-backed implementation can come later.
    case dict([DictEntry])
    /// Set, stored as an ordered list of unique elements (insertion order
    /// preserved). Same linear-lookup tradeoff as `.dict`. Equality is
    /// order-insensitive, matching Swift's Set semantics.
    case set([Value])
    /// Opaque carrier for a host-Swift value (CharacterSet, URL, Date,
    /// Data, …) that we don't model structurally. The bridge generator
    /// uses this for symbols whose parameters/returns are host types we
    /// can't decompose into primitives. `typeName` is used for type
    /// checks at unbox sites; `value` is the actual Swift instance held
    /// as `Any`.
    case opaque(typeName: String, value: Any)
    /// Instance of a user-defined struct. Fields are stored in declaration
    /// order so we can render them the same way Swift does.
    case structValue(typeName: String, fields: [StructField])
    /// Instance of a user-defined class. Wraps a reference cell so two
    /// `Value`s holding the same instance see each other's mutations —
    /// the defining trait of class semantics in Swift.
    case classInstance(ClassInstance)
    /// Instance of a user-defined enum. `associatedValues` is empty for
    /// payload-less cases; matches Swift's display, equality, etc.
    case enumValue(typeName: String, caseName: String, associatedValues: [Value])
}

public struct StructField {
    public let name: String
    public var value: Value
    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }
}

public struct DictEntry {
    public let key: Value
    public var value: Value
    public init(key: Value, value: Value) {
        self.key = key
        self.value = value
    }
}

extension Value {
    /// Build an unlabeled tuple. Most call sites — operator results,
    /// destructured-iter outputs, dict-iter pairs without label semantics
    /// — don't carry labels, and writing `.tuple(xs, labels: [...])` for
    /// each one would be noisy.
    public static func tuple(_ elements: [Value]) -> Value {
        return .tuple(elements, labels: [])
    }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int(let i):    return String(i)
        case .double(let d): return formatDouble(d)
        case .string(let s): return s
        case .bool(let b):   return String(b)
        case .void:          return "()"
        case .function(let f): return "<function \(f.name)>"
        case .range(let lo, let hi, let closed):
            return closed ? "\(lo)...\(hi)" : "\(lo)..<\(hi)"
        case .array(let xs):
            return "[" + xs.map(\.elementDescription).joined(separator: ", ") + "]"
        case .optional(let inner):
            if let inner { return "Optional(\(inner.elementDescription))" }
            return "nil"
        case .tuple(let elements, let labels):
            // Labeled rendering only when each position has a label.
            if !labels.isEmpty,
               labels.count == elements.count,
               labels.allSatisfy({ $0 != nil })
            {
                let parts = zip(labels, elements).map {
                    "\($0.0!): \($0.1.elementDescription)"
                }
                return "(" + parts.joined(separator: ", ") + ")"
            }
            return "(" + elements.map(\.elementDescription).joined(separator: ", ") + ")"
        case .dict(let entries):
            if entries.isEmpty { return "[:]" }
            let parts = entries.map { "\($0.key.elementDescription): \($0.value.elementDescription)" }
            return "[" + parts.joined(separator: ", ") + "]"
        case .set(let xs):
            // Swift's `Set` doesn't promise iteration order in its
            // description, so probe outputs that print a Set verbatim
            // diverge between runs. We sort by stringified form to give
            // a stable rendering — divergence from native Swift in the
            // happy path is unavoidable, but stability matters more
            // for our probe harness.
            let sorted = xs.map(\.elementDescription).sorted()
            return "Set([" + sorted.joined(separator: ", ") + "])"
        case .opaque(_, let value):
            // Defer to the host-Swift `String(describing:)` — produces
            // a sensible default for most Foundation types.
            return String(describing: value)
        case .structValue(let typeName, let fields):
            let parts = fields.map { "\($0.name): \($0.value.elementDescription)" }
            return "\(typeName)(\(parts.joined(separator: ", ")))"
        case .classInstance(let inst):
            // Match Swift's default class description: type name only —
            // distinct instances aren't readily distinguished by print.
            return inst.typeName
        case .enumValue(_, let caseName, let payload):
            // Matches Swift's default printing: bare case name, with
            // payload tuple for associated values.
            if payload.isEmpty { return caseName }
            let parts = payload.map(\.elementDescription).joined(separator: ", ")
            return "\(caseName)(\(parts))"
        }
    }

    /// Used when this value appears inside another collection (Array, Tuple,
    /// Optional). Strings are quoted to match Swift's `print([…])` output.
    fileprivate var elementDescription: String {
        if case .string(let s) = self {
            return "\"\(s)\""
        }
        return description
    }
}

extension Value: Equatable {
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case let (.int(a), .int(b)):       return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)):    return Double(a) == b
        case let (.double(a), .int(b)):    return a == Double(b)
        case let (.string(a), .string(b)): return a == b
        case let (.bool(a), .bool(b)):     return a == b
        case (.void, .void):               return true
        case let (.range(la, lb, lc), .range(ra, rb, rc)):
            return la == ra && lb == rb && lc == rc
        case let (.array(a), .array(b)):
            return a == b
        case let (.optional(a), .optional(b)):
            return a == b
        case let (.tuple(a, _), .tuple(b, _)):
            // Labels don't affect equality (Swift treats `(x, y)` and
            // `(a: x, b: y)` as equal-shaped for `==`).
            return a == b
        case let (.dict(a), .dict(b)):
            // Order-insensitive: same set of (key, value) pairs.
            guard a.count == b.count else { return false }
            return a.allSatisfy { ax in
                b.contains { ax.key == $0.key && ax.value == $0.value }
            }
        case let (.set(a), .set(b)):
            // Order-insensitive set equality.
            guard a.count == b.count else { return false }
            return a.allSatisfy { ax in b.contains { $0 == ax } }
        case let (.opaque(an, _), .opaque(bn, _)) where an == bn:
            // We don't have a generic host-Equatable hook. For PoC: opaque
            // values compare equal only if the *same* boxed reference. For
            // value types this gives false-negatives but never false-
            // positives — safe default until users explicitly bridge an `==`.
            return false
        case let (.structValue(an, af), .structValue(bn, bf)):
            guard an == bn, af.count == bf.count else { return false }
            return zip(af, bf).allSatisfy { $0.name == $1.name && $0.value == $1.value }
        case let (.classInstance(a), .classInstance(b)):
            // Identity equality — Swift's `==` for class instances uses
            // referential identity unless the user supplies an Equatable
            // conformance (we don't model the latter yet).
            return a === b
        case let (.enumValue(an, ac, av), .enumValue(bn, bc, bv)):
            return an == bn && ac == bc && av == bv
        default:
            return false
        }
    }
}

extension Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .int(let n):    hasher.combine(0); hasher.combine(n)
        case .double(let d): hasher.combine(1); hasher.combine(d)
        case .string(let s): hasher.combine(2); hasher.combine(s)
        case .bool(let b):   hasher.combine(3); hasher.combine(b)
        case .void:          hasher.combine(4)
        case .range(let lo, let hi, let closed):
            hasher.combine(5); hasher.combine(lo); hasher.combine(hi); hasher.combine(closed)
        case .array(let xs):
            hasher.combine(6); for x in xs { hasher.combine(x) }
        case .optional(let inner):
            hasher.combine(7); hasher.combine(inner)
        case .tuple(let elements, _):
            // Labels don't affect hash (matching equality semantics).
            hasher.combine(8); for el in elements { hasher.combine(el) }
        case .dict(let entries):
            // Order-insensitive: hash the multiset of (k, v) pairs by
            // XORing each pair's hash.
            hasher.combine(9)
            var combined: Int = 0
            for entry in entries {
                var h = Hasher()
                h.combine(entry.key); h.combine(entry.value)
                combined ^= h.finalize()
            }
            hasher.combine(combined)
        case .set(let xs):
            hasher.combine(10)
            var combined: Int = 0
            for x in xs {
                var h = Hasher()
                h.combine(x)
                combined ^= h.finalize()
            }
            hasher.combine(combined)
        case .opaque(let n, _):
            // Opaque payloads aren't reliably Hashable (Any). Hash by
            // type name only — false-positives are safe because
            // Equatable already returns false for distinct opaque values.
            hasher.combine(11); hasher.combine(n)
        case .structValue(let n, let fields):
            hasher.combine(12); hasher.combine(n)
            for f in fields { hasher.combine(f.name); hasher.combine(f.value) }
        case .classInstance(let inst):
            // Identity-based, matching `===` Equatable behavior.
            hasher.combine(13); hasher.combine(ObjectIdentifier(inst))
        case .enumValue(let n, let c, let payload):
            hasher.combine(14); hasher.combine(n); hasher.combine(c)
            for v in payload { hasher.combine(v) }
        case .function(let f):
            hasher.combine(15); hasher.combine(f.name)
        }
    }
}

public func typeName(_ value: Value) -> String {
    switch value {
    case .int:      return "Int"
    case .double:   return "Double"
    case .string:   return "String"
    case .bool:     return "Bool"
    case .void:     return "Void"
    case .function: return "Function"
    case .range:    return "Range"
    case .array(let xs):
        // Mirror swiftc's `'[Int]'` wording when the elements are all
        // the same scalar type. Heterogeneous / empty arrays fall back
        // to `'[Element]'` (the placeholder swiftc shows for an unknown
        // element type).
        return "[\(elementSpelling(of: xs))]"
    case .optional(let inner):
        if let inner { return "\(typeName(inner))?" }
        return "Optional"
    case .tuple(_, _):    return "Tuple"
    case .structValue(let n, _): return n
    case .classInstance(let i):  return i.typeName
    case .enumValue(let n, _, _): return n
    case .dict(let entries):
        if let first = entries.first {
            return "[\(typeName(first.key)) : \(typeName(first.value))]"
        }
        return "[AnyHashable : Any]"
    case .set(let xs): return "Set<\(elementSpelling(of: xs))>"
    case .opaque(let n, _): return n
    }
}

/// Pick the most specific element-type spelling for a homogeneous
/// collection. Used to render `[Int]` / `Set<String>` etc. in error
/// messages so they line up with swiftc's wording.
private func elementSpelling(of xs: [Value]) -> String {
    guard let first = xs.first else { return "Element" }
    let t = typeName(first)
    return xs.allSatisfy { typeName($0) == t } ? t : "Element"
}

/// Generic-shape name used for extension-registry lookup: `Array` for
/// any `.array`, `Set` for any `.set`, etc. Distinct from `typeName`
/// which now produces parameterized spellings (`[Int]`, `Set<String>`)
/// for diagnostics.
public func registryTypeName(_ value: Value) -> String {
    switch value {
    case .array:    return "Array"
    case .set:      return "Set"
    case .dict:     return "Dictionary"
    case .optional: return "Optional"
    case .range:    return "Range"
    default:        return typeName(value)
    }
}

public struct Function {
    public let name: String
    public let parameters: [Parameter]
    /// User-declared return type, if the function has one. Used for return-
    /// value coercion. `nil` for builtins and for functions without
    /// `-> Type` (in which case the implicit return type is `Void`).
    public let returnType: TypeSyntax?
    /// True for `mutating` struct methods. Causes `self` to bind as mutable
    /// inside the body, and forces the call site to write the modified
    /// value back to the receiver variable after the call returns.
    public let isMutating: Bool
    /// Generic-parameter names declared by the function, e.g.
    /// `func foo<T, U>(...)` → `["T", "U"]`. Pushed onto
    /// `Interpreter.genericTypeParameters` while the body runs so type
    /// validation inside the function recognizes them as known.
    public let genericParameters: [String]
    /// Owning type name when this function is a `static func` / static
    /// getter. Pushed onto `Interpreter.staticContextStack` while the body
    /// runs so unqualified identifier reads/writes resolve against the
    /// type's `staticMembers`.
    public let staticContext: String?
    /// `init?(...)` — failable initializer. The instantiator wraps the
    /// result in `Optional<T>`, and a `return nil` in the body short-
    /// circuits to `.optional(nil)`. Plain non-failable inits stay non-
    /// optional.
    public let isFailable: Bool
    public let kind: Kind

    public init(
        name: String,
        parameters: [Parameter],
        returnType: TypeSyntax? = nil,
        isMutating: Bool = false,
        genericParameters: [String] = [],
        staticContext: String? = nil,
        isFailable: Bool = false,
        kind: Kind
    ) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.isMutating = isMutating
        self.genericParameters = genericParameters
        self.staticContext = staticContext
        self.isFailable = isFailable
        self.kind = kind
    }

    public enum Kind {
        /// Built-in implementation. Async-throwing so registered builtins
        /// can call host async APIs (`URLSession.shared.data(from:)`,
        /// `try await Task.sleep`, …) and have the script's `await`
        /// actually suspend on them.
        case builtin(([Value]) async throws -> Value)
        /// Like `.builtin` but receives the receiver value separately.
        /// Used for module-registered instance methods on built-in types,
        /// where dispatch needs to pass `self` to the implementation.
        case builtinMethod((_ receiver: Value, _ args: [Value]) async throws -> Value)
        /// User-defined function or closure body. Both `func foo() { … }`
        /// and `{ x in … }` produce the same shape — a list of code-block
        /// items plus the captured lexical scope.
        case user(body: CodeBlockItemListSyntax, capturedScope: Scope)
    }

    public struct Parameter {
        public let label: String?
        public let name: String
        /// Declared parameter type, used for implicit-coercion at call site.
        /// `nil` for builtins (which take raw `Value`s).
        public let type: TypeSyntax?
        /// Variadic parameter, declared `xs: Int...`. At call time the
        /// trailing positional args (from this parameter onwards) are
        /// gathered into an `.array` so the body sees `xs` as `[Int]`.
        public let isVariadic: Bool
        /// Default-value expression for `prefix: String = "Hello"`. Evaluated
        /// lazily in the function's captured scope when a call omits this
        /// argument.
        public let defaultValue: ExprSyntax?
        /// `inout` parameter (`n: inout Int`). The call site evaluates the
        /// l-value, passes the current value as the arg, then writes back
        /// the body's final binding to the same l-value when invoke returns.
        public let isInout: Bool

        public init(
            label: String?,
            name: String,
            type: TypeSyntax? = nil,
            isVariadic: Bool = false,
            defaultValue: ExprSyntax? = nil,
            isInout: Bool = false
        ) {
            self.label = label
            self.name = name
            self.type = type
            self.isVariadic = isVariadic
            self.defaultValue = defaultValue
            self.isInout = isInout
        }
    }
}

private func formatDouble(_ d: Double) -> String {
    if d == d.rounded() && abs(d) < 1e16 {
        return String(format: "%.1f", d)
    }
    return String(d)
}
