import Foundation

public enum RuntimeError: Error, CustomStringConvertible {
    case unsupported(String, at: Int)
    case invalid(String)
    case unknownIdentifier(String, at: Int)
    case divisionByZero

    public var description: String {
        switch self {
        case .unsupported(let s, _):
            return "unsupported \(s)"
        case .invalid(let s):
            return s
        case .unknownIdentifier(let n, _):
            return "cannot find '\(n)' in scope"
        case .divisionByZero:
            return "division by zero"
        }
    }

    /// Source offset of the failing expression, when known. Used by
    /// `Interpreter.renderRuntimeError` to render `swiftc`-style carets.
    public var offset: Int? {
        switch self {
        case .unsupported(_, let at):       return at
        case .unknownIdentifier(_, let at): return at
        case .invalid, .divisionByZero:     return nil
        }
    }
}

/// Non-local exit thrown by `return` and caught by the function call frame.
struct ReturnSignal: Error, @unchecked Sendable {
    let value: Value
}

/// Thrown by `break`, caught by the enclosing loop. An optional `label`
/// targets a specific labeled loop; if `nil`, breaks the innermost loop.
struct BreakSignal: Error { let label: String? }

/// Thrown by `continue`, caught by the enclosing loop. An optional `label`
/// targets a specific labeled loop; if `nil`, continues the innermost.
struct ContinueSignal: Error { let label: String? }

/// Wraps a value thrown from script `throw` so it can travel through
/// host async/throwing code and be caught with normal Swift `catch`
/// clauses. The thrown enum / struct payload is available as `value`,
/// with convenience accessors for the most common shapes.
public struct ScriptError: Error, CustomStringConvertible, @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Compatibility init matching the old `UserThrowSignal(value:)`
    /// shape used at every interpreter throw site. Keeps the existing
    /// runtime call sites unchanged.
    init(value: Value) {
        self.value = value
    }

    /// Type name of the thrown value (`E` in `throw E.bad`, struct name
    /// for struct payloads). Nil for primitives or composite values
    /// without a type name.
    public var typeName: String? {
        switch value {
        case .enumValue(let n, _, _): return n
        case .structValue(let n, _):  return n
        case .classInstance(let i):   return i.typeName
        default: return nil
        }
    }

    /// Case name when the thrown value is an enum case.
    public var caseName: String? {
        if case .enumValue(_, let c, _) = value { return c }
        return nil
    }

    public var description: String {
        switch value {
        case .enumValue(let n, let c, let payload):
            if payload.isEmpty { return "\(n).\(c)" }
            return "\(n).\(c)(\(payload.map { "\($0)" }.joined(separator: ", ")))"
        default:
            return String(describing: value)
        }
    }
}

extension ScriptError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Internal alias. The runtime threw `UserThrowSignal` historically;
/// keeping the name lets the existing catch sites compile unchanged
/// while host callers see a `ScriptError`.
typealias UserThrowSignal = ScriptError

/// Thrown by `fallthrough`; caught by the enclosing switch's case-execution
/// loop, which then runs the next case's body without checking its pattern.
struct FallthroughSignal: Error {}

extension BreakSignal {
    /// Whether this signal applies to a loop with the given label.
    /// Unlabeled signals match any loop; labeled ones only match their target.
    func matches(_ loopLabel: String?) -> Bool {
        label == nil || label == loopLabel
    }
}

extension ContinueSignal {
    func matches(_ loopLabel: String?) -> Bool {
        label == nil || label == loopLabel
    }
}
