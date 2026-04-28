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
struct ReturnSignal: Error {
    let value: Value
}

/// Thrown by `break`, caught by the enclosing loop. An optional `label`
/// targets a specific labeled loop; if `nil`, breaks the innermost loop.
struct BreakSignal: Error { let label: String? }

/// Thrown by `continue`, caught by the enclosing loop. An optional `label`
/// targets a specific labeled loop; if `nil`, continues the innermost.
struct ContinueSignal: Error { let label: String? }

/// Raised by a `throw` statement; caught by `do/catch` or surfaces as a
/// runtime error if uncaught at the top level.
struct UserThrowSignal: Error {
    let value: Value
}

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
