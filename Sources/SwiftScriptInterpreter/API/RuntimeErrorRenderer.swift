import SwiftSyntax
import SwiftDiagnostics

extension Interpreter {
    /// Render a `RuntimeError` in the same format as `swiftc` parse errors:
    /// a `<file>:<line>:<col>: error: <msg>` header followed by the
    /// `DiagnosticsFormatter`-rendered source line with caret pointer.
    /// Falls back to a plain `error: <msg>` line when the error has no
    /// associated offset or no source tree is in scope.
    public func renderRuntimeError(_ error: Error) -> String {
        guard let runtime = error as? RuntimeError,
              let offset = runtime.offset,
              let tree = currentSourceFile,
              let fileName = currentFileName
        else {
            return "error: \(error)\n"
        }

        let position = AbsolutePosition(utf8Offset: offset)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let loc = converter.location(for: position)

        var output = "\(loc.file):\(loc.line):\(loc.column): error: \(runtime.description)\n"
        let diag = SwiftDiagnostics.Diagnostic(
            node: Syntax(tree),
            position: position,
            message: RuntimeDiagnosticMessage(text: runtime.description)
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
