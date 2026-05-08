import ShellKit

/// Thrown by the `exit(_:)` and `abort()` builtins to unwind the
/// interpreter back to the host.
///
/// Caught at the eval boundary in ``Interpreter/evalScript(_:fileName:)``,
/// which converts it back into an ``ShellKit/ExitStatus`` the host
/// can return / propagate. ``Interpreter/eval(_:fileName:)`` lets it
/// propagate so callers that use the older `Value`-returning API see
/// the thrown signal directly.
///
/// This type is `internal`-shaped on purpose: a script can't catch
/// `ScriptExit` from script-side `try / catch` because the dispatcher
/// rethrows past `do/catch` blocks (matching how Swift's own `exit`
/// is unrecoverable from inside the running program). Hosts catch it
/// at the very edge.
public struct ScriptExit: Error, Sendable, CustomStringConvertible {
    public let status: ExitStatus
    public init(status: ExitStatus) { self.status = status }
    public init(_ code: Int32) { self.status = ExitStatus(code) }

    public var description: String {
        "ScriptExit(\(status.code))"
    }
}
