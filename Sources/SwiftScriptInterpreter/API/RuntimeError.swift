import Foundation

public enum RuntimeError: Error, CustomStringConvertible {
    case unsupported(String, at: Int)
    /// `at:` is the source offset of the failing expression, attached
    /// by the evaluator on the way out when the raising site didn't
    /// know it (issue #15). It's a payload, not a wrapper case, so
    /// position never changes what the error *is* — `if case
    /// .invalid(let msg, _)` matches whether or not a position was
    /// attached. Position-less throw sites keep the old one-argument
    /// spelling via the `invalid(_:)` factory below.
    case invalid(String, at: Int?)
    case unknownIdentifier(String, at: Int)
    case divisionByZero(at: Int?)

    /// Source-compatible constructor for the position-less spelling —
    /// `RuntimeError.invalid("message")` at a raise site resolves here
    /// and produces `.invalid("message", at: nil)`. (Enum cases can't
    /// take default arguments, so the default lives in this factory.)
    public static func invalid(_ message: String) -> RuntimeError {
        .invalid(message, at: nil)
    }

    public var description: String {
        switch self {
        case .unsupported(let s, _):
            return "unsupported \(s)"
        case .invalid(let s, _):
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
        case .invalid(_, let at):           return at
        case .divisionByZero(let at):       return at
        }
    }

    /// Attach a source offset to an error that doesn't carry one yet.
    /// An error that already knows its position keeps it — the earliest
    /// (innermost) stamp wins, since it is the most precise.
    public func positioned(at offset: Int?) -> RuntimeError {
        guard let offset, self.offset == nil else { return self }
        switch self {
        case .invalid(let message, _):
            return .invalid(message, at: offset)
        case .divisionByZero:
            return .divisionByZero(at: offset)
        case .unsupported, .unknownIdentifier:
            return self
        }
    }
}

/// Non-local exit thrown by `return` and caught by the function call frame.
struct ReturnSignal: Error {
    let value: Value
}

/// Thrown by `break`, caught by the enclosing loop. An optional `label`
/// targets a specific labeled loop; if `nil`, breaks the innermost loop.
struct BreakSignal: Error { let label: String? }

/// Thrown by `continue`, caught by the enclosing loop. An optional `label`
/// targets a specific labeled loop; if `nil`, continues the innermost.
struct ContinueSignal: Error { let label: String? }

/// Marker for host errors that must reach the host — never a script
/// `catch`. By default, an error thrown from a bridge or registered
/// builtin becomes a catchable `ScriptError`, which means any script
/// can `try?` it away. A host that throws errors *as control flow* —
/// skip this run, deadline exceeded, quota exhausted — conforms those
/// types to this protocol, and both invocation boundaries let them
/// pass through raw, the way `ScriptExit` already does. No source
/// position is attached: these are signals to the host, not
/// diagnostics for the script.
public protocol ScriptUncatchableError: Error {}

/// Wraps a value thrown from script `throw` so it can travel through
/// host async/throwing code and be caught with normal Swift `catch`
/// clauses. The thrown enum / struct payload is available as `value`,
/// with convenience accessors for the most common shapes.
public struct ScriptError: Error, CustomStringConvertible {
    public let value: Value

    /// UTF-8 source offset of the expression or `throw` statement this
    /// error was raised from, when known — issue #15. Set by the
    /// interpreter (at the bridge boundary, at `throw` statements, and
    /// as a fallback by the expression evaluator) so an uncaught error
    /// can be rendered with source context via
    /// ``Interpreter/renderRuntimeError(_:)``.
    public let offset: Int?

    public init(_ value: Value, offset: Int? = nil) {
        self.value = value
        self.offset = offset
    }

    /// Compatibility init matching the old `UserThrowSignal(value:)`
    /// shape used at every interpreter throw site. Keeps the existing
    /// runtime call sites unchanged.
    init(value: Value, offset: Int? = nil) {
        self.value = value
        self.offset = offset
    }

    /// Attach a source offset if this error doesn't carry one yet; the
    /// earliest (innermost) stamp wins. Same contract as
    /// ``RuntimeError/positioned(at:)``.
    func positioned(at offset: Int?) -> ScriptError {
        guard let offset, self.offset == nil else { return self }
        return ScriptError(value: value, offset: offset)
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

    /// The underlying host `Error` when this wraps one — an error a
    /// bridge or registered builtin threw, boxed opaquely so script
    /// `catch` could bind it. Hosts recover their own error types here
    /// (`scriptError.hostError as? MySentinel`) instead of unpacking
    /// the `.opaque` payload by hand. Nil for script-thrown values.
    public var hostError: (any Error)? {
        if case .opaque(_, let payload) = value { return payload as? any Error }
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
