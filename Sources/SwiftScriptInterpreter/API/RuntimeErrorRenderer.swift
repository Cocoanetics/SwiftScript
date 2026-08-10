import SwiftSyntax
import SwiftDiagnostics

extension Interpreter {
    /// Render an error in the same format as `swiftc` parse errors:
    /// a `<file>:<line>:<col>: error: <msg>` header followed by the
    /// `DiagnosticsFormatter`-rendered source line with caret pointer.
    /// Handles a `RuntimeError` carrying an offset and a `ScriptError`
    /// (an uncaught script `throw` or bridge error) stamped with one.
    /// Falls back to a plain `error: <msg>` line when the error has no
    /// associated offset or no source tree is in scope.
    public func renderRuntimeError(_ error: Error) -> String {
        if let runtime = error as? RuntimeError, let offset = runtime.offset {
            return renderSourceContext(at: offset, message: runtime.description)
        }
        if let script = error as? ScriptError, let offset = script.offset {
            return renderSourceContext(at: offset, message: script.description)
        }
        return "error: \(error)\n"
    }

    /// Render `message` against the most recently evaluated source, with
    /// the `<file>:<line>:<col>: error:` header and caret-annotated
    /// source line pointing at `offset` (a UTF-8 offset as reported by
    /// ``currentCallOffset`` or `RuntimeError.offset`) — issue #16.
    ///
    /// This is the same output an uncaught error gets from
    /// ``renderRuntimeError(_:)``, exposed for failures that never
    /// become an `Error` at all: a host whose assertion builtins record
    /// issues and continue (Swift Testing / XCTest semantics) renders
    /// each recorded issue here, so it reads exactly like a thrown one.
    ///
    /// Falls back to a plain `error: <msg>` line when no source tree is
    /// in scope (nothing evaluated yet). Offsets outside the current
    /// tree are clamped to its end. Offsets are only meaningful against
    /// the script they came from — render recorded issues before
    /// evaluating another script on the same interpreter.
    public func renderSourceContext(at offset: Int, message: String) -> String {
        guard let tree = currentSourceFile, let fileName = currentFileName else {
            return "error: \(message)\n"
        }

        let clamped = min(max(offset, 0), tree.totalLength.utf8Length)
        let position = AbsolutePosition(utf8Offset: clamped)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let loc = converter.location(for: position)

        var output = "\(loc.file):\(loc.line):\(loc.column): error: \(message)\n"
        let diag = SwiftDiagnostics.Diagnostic(
            node: Syntax(tree),
            position: position,
            message: RuntimeDiagnosticMessage(text: message)
        )
        output += DiagnosticsFormatter.annotatedSource(tree: tree, diags: [diag])
        if !output.hasSuffix("\n") { output += "\n" }
        return output
    }
}

private struct RuntimeDiagnosticMessage: SwiftDiagnostics.DiagnosticMessage {
    let text: String
    var message: String { text }
    var diagnosticID: MessageID { MessageID(domain: "SwiftScript", id: "runtime") }
    var severity: DiagnosticSeverity { .error }
}
