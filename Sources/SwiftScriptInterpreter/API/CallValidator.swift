import Foundation

/// Description of a callable's signature for swiftc-shaped argument
/// validation. Used by call sites (bridge dispatch, user-function
/// invocation, initializers) to reject malformed calls with the same
/// diagnostics swiftc produces — script users get familiar wording.
///
/// Today the structure is hand-built per call site; the bridge generator
/// (and SwiftSyntax for user functions) can populate it mechanically
/// from existing metadata.
public struct CallSignature: Sendable {
    public struct Parameter: Sendable {
        /// External label seen at the call site. `nil` for `_:`.
        public let label: String?
        /// Internal name (used in `missing argument for parameter '<name>'`).
        public let name: String
        /// Expected runtime shape.
        public let type: ParameterType
        /// `true` when the parameter has `= default`, so it can be
        /// omitted at the call site.
        public let hasDefault: Bool

        public init(label: String?, name: String, type: ParameterType, hasDefault: Bool = false) {
            self.label = label
            self.name = name
            self.type = type
            self.hasDefault = hasDefault
        }
    }

    /// Pretty name for diagnostics — e.g. `"Calendar.nextWeekend(startingAfter:)"`.
    public let name: String
    public let parameters: [Parameter]

    public init(name: String, parameters: [Parameter]) {
        self.name = name
        self.parameters = parameters
    }
}

/// What kind of value a parameter accepts. Granular enough for the
/// common Swift types; falls back to `.any` for protocol-bound or
/// generic positions where the validator can't usefully check.
public enum ParameterType: Sendable {
    case int, double, string, bool
    case opaque(String)              // bridged Foundation type: "Date", "URL", …
    case array, set, dict, range
    case function
    indirect case `optional`(ParameterType)
    /// Accept any value — protocol-bound or generic param.
    case any
    /// User-declared struct/class/enum by name.
    case named(String)
}

/// One call-site argument: the label the caller wrote (or nil for an
/// unlabelled positional) and the evaluated value. Not `Sendable` —
/// `Value` carries closures and opaque payloads that aren't.
public struct CallArgument {
    public let label: String?
    public let value: Value
    public init(label: String?, value: Value) {
        self.label = label
        self.value = value
    }
}

/// Mismatches the validator can report. `description` reproduces
/// swiftc's exact wording so the script-facing error reads the same.
public enum CallValidationError: Error, CustomStringConvertible {
    case noArgsAllowed
    case missingArgument(parameter: String)
    case missingArgumentLabel(label: String)
    case extraArgument(label: String?)
    case incorrectLabels(have: String, expected: String)
    case typeMismatch(value: String, expected: String)

    public var description: String {
        switch self {
        case .noArgsAllowed:
            return "argument passed to call that takes no arguments"
        case .missingArgument(let p):
            return "missing argument for parameter '\(p)' in call"
        case .missingArgumentLabel(let l):
            return "missing argument label '\(l):' in call"
        case .extraArgument(let label):
            if let label { return "extra argument '\(label)' in call" }
            return "extra argument in call"
        case .incorrectLabels(let have, let expected):
            return "incorrect argument label in call (have '\(have)', expected '\(expected)')"
        case .typeMismatch(let v, let e):
            return "cannot convert value of type '\(v)' to expected argument type '\(e)'"
        }
    }
}

/// Validate `args` against `signature`. Throws on the first mismatch,
/// matching swiftc's stop-at-first-error behavior. Order of checks:
///
///   1. Arity (call has too many / too few args)
///   2. Labels (per-position match against the signature)
///   3. Types (per-position runtime shape)
public func validate(
    arguments args: [CallArgument],
    against sig: CallSignature
) throws {
    // 1. Arity.
    if sig.parameters.isEmpty && !args.isEmpty {
        throw CallValidationError.noArgsAllowed
    }
    let required = sig.parameters.filter { !$0.hasDefault }.count
    if args.count < required {
        // First param the call didn't reach. (Defaults at the end is
        // the common shape; see file-level note for the rare interleaved
        // case.)
        let missing = sig.parameters[args.count]
        throw CallValidationError.missingArgument(parameter: missing.name)
    }
    if args.count > sig.parameters.count {
        let extra = args[sig.parameters.count]
        throw CallValidationError.extraArgument(label: extra.label)
    }

    // 2. Labels. Walk in lock-step; collect mismatches so we can pick
    // the most specific diagnostic.
    var firstMismatch: Int?
    var mismatchCount = 0
    for (i, arg) in args.enumerated() {
        if arg.label != sig.parameters[i].label {
            mismatchCount += 1
            if firstMismatch == nil { firstMismatch = i }
        }
    }
    if let i = firstMismatch {
        // Special-case the single-missing-label form: one arg, no label,
        // where a label was expected. swiftc reports
        // `missing argument label 'X:' in call`.
        if mismatchCount == 1,
           args[i].label == nil,
           let expected = sig.parameters[i].label
        {
            throw CallValidationError.missingArgumentLabel(label: expected)
        }
        let have = args.map { ($0.label ?? "_") + ":" }.joined()
        let expected = sig.parameters.map { ($0.label ?? "_") + ":" }.joined()
        throw CallValidationError.incorrectLabels(have: have, expected: expected)
    }

    // 3. Types.
    for (i, arg) in args.enumerated() {
        let param = sig.parameters[i]
        if !valueMatches(arg.value, param.type) {
            throw CallValidationError.typeMismatch(
                value: typeName(arg.value),
                expected: describe(param.type)
            )
        }
    }
}

/// True if `value` is assignable to a parameter slot of `type`.
/// Honors the same implicit conversions Swift accepts at call sites:
///   - `Int` → `Double`
///   - `T` → `T?`  (optional promotion)
private func valueMatches(_ value: Value, _ type: ParameterType) -> Bool {
    switch type {
    case .int:
        if case .int = value { return true }
    case .double:
        if case .double = value { return true }
        if case .int = value { return true }
    case .string:
        if case .string = value { return true }
    case .bool:
        if case .bool = value { return true }
    case .opaque(let name):
        if case .opaque(let t, _) = value, t == name { return true }
    case .array:
        if case .array = value { return true }
    case .set:
        if case .set = value { return true }
    case .dict:
        if case .dict = value { return true }
    case .range:
        if case .range = value { return true }
    case .function:
        if case .function = value { return true }
    case .optional(let inner):
        if case .optional(.none) = value { return true }
        if case .optional(.some(let v)) = value { return valueMatches(v, inner) }
        return valueMatches(value, inner)
    case .any:
        return true
    case .named(let name):
        return registryTypeName(value) == name
    }
    return false
}

/// Spelling for type-mismatch errors — e.g. `Int`, `String`, `Date?`.
private func describe(_ type: ParameterType) -> String {
    switch type {
    case .int: return "Int"
    case .double: return "Double"
    case .string: return "String"
    case .bool: return "Bool"
    case .opaque(let n): return n
    case .named(let n): return n
    case .array: return "Array"
    case .set: return "Set"
    case .dict: return "Dictionary"
    case .range: return "Range"
    case .function: return "Function"
    case .optional(let inner): return describe(inner) + "?"
    case .any: return "Any"
    }
}
