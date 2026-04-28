import SwiftSyntax
import SwiftParser
import SwiftOperators
import SwiftDiagnostics
import SwiftParserDiagnostics

public struct ParseResult {
    public let sourceFile: SourceFileSyntax
    public let fileName: String
    /// Diagnostics produced by the parser, mapped to `line:column` source
    /// locations. Includes errors and warnings.
    public let diagnostics: [Diagnostic]

    /// Raw SwiftDiagnostics objects, kept around so we can format errors
    /// in the canonical `swiftc` style with source context and carets.
    let rawDiagnostics: [SwiftDiagnostics.Diagnostic]

    /// True if any diagnostic has error severity.
    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// Just the error-severity diagnostics, in source order.
    public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }

    /// `swiftc`-style multi-line diagnostic formatting with source-line
    /// context and caret pointers. Each diagnostic is preceded by a
    /// `<file>:<line>:<col>: <severity>: <message>` header line, matching
    /// what `swift -` emits. Empty string if there are no diagnostics.
    public func formattedDiagnostics(colorize: Bool = false) -> String {
        guard !rawDiagnostics.isEmpty else { return "" }
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        var output = ""
        for (index, diag) in rawDiagnostics.enumerated() {
            let loc = diag.location(converter: converter)
            output += "\(loc.file):\(loc.line):\(loc.column): \(severityWord(diag.diagMessage.severity)): \(diag.message)\n"
            output += DiagnosticsFormatter.annotatedSource(
                tree: sourceFile,
                diags: [diag],
                colorize: colorize
            )
            if !output.hasSuffix("\n") { output += "\n" }
            if index < rawDiagnostics.count - 1 { output += "\n" }
        }
        return output
    }
}

private func severityWord(_ s: DiagnosticSeverity) -> String {
    switch s {
    case .error:   return "error"
    case .warning: return "warning"
    case .note:    return "note"
    case .remark:  return "remark"
    @unknown default: return "error"
    }
}

public struct Diagnostic: CustomStringConvertible, Sendable {
    public enum Severity: Sendable { case error, warning, note, remark }

    public let severity: Severity
    public let message: String
    public let line: Int
    public let column: Int
    public let offset: Int

    public var description: String {
        "\(severity): line \(line):\(column): \(message)"
    }
}

public enum ScriptParser {
    public static func parse(_ source: String, fileName: String = "<input>") -> ParseResult {
        let parsed = Parser.parse(source: source)
        let rawDiagnostics = ParseDiagnosticsGenerator.diagnostics(for: parsed)

        let converter = SourceLocationConverter(fileName: fileName, tree: parsed)
        let diagnostics = rawDiagnostics.map { rawDiagnostic -> Diagnostic in
            let location = rawDiagnostic.location(converter: converter)
            return Diagnostic(
                severity: map(rawDiagnostic.diagMessage.severity),
                message: rawDiagnostic.message,
                line: location.line,
                column: location.column,
                offset: location.offset
            )
        }

        // Pull any `precedencegroup` / `operator` declarations out of the
        // source into the table before folding, so user-defined operators
        // (e.g. `infix operator **`) participate in precedence/associativity
        // resolution alongside the standard ones.
        var opTable = OperatorTable.standardOperators
        try? opTable.addSourceFile(parsed)
        let folded = opTable.foldAll(parsed) { _ in }
        let sourceFile = folded.as(SourceFileSyntax.self) ?? parsed
        return ParseResult(
            sourceFile: sourceFile,
            fileName: fileName,
            diagnostics: diagnostics,
            rawDiagnostics: rawDiagnostics
        )
    }
}

private func map(_ severity: DiagnosticSeverity) -> Diagnostic.Severity {
    switch severity {
    case .error:   return .error
    case .warning: return .warning
    case .note:    return .note
    case .remark:  return .remark
    @unknown default: return .error
    }
}
