import Testing
@testable import SwiftScriptInterpreter
import SwiftScriptAST

@Suite("Parser diagnostics")
struct ParseErrorTests {
    @Test func incompleteExpressionThrows() async throws {
        let interp = Interpreter()
        do {
            _ = try await interp.eval("1 +")
            Issue.record("expected ParseError")
        } catch let parseError as ParseError {
            #expect(!parseError.diagnostics.isEmpty)
            #expect(parseError.diagnostics.contains { $0.severity == .error })
        } catch {
            Issue.record("expected ParseError, got \(error)")
        }
    }

    @Test func diagnosticHasLineColumn() async throws {
        let result = ScriptParser.parse("if true {\n  print(\"hi\")")
        #expect(result.hasErrors)
        let firstError = result.errors.first!
        #expect(firstError.line >= 1)
        #expect(firstError.column >= 1)
        #expect(firstError.message.lowercased().contains("}"))
    }

    @Test func validSourceHasNoErrors() async throws {
        let result = ScriptParser.parse("let x = 1 + 2\nprint(x)")
        #expect(result.hasErrors == false)
        #expect(result.errors.isEmpty)
    }

    @Test func multipleErrorsCollected() async throws {
        let result = ScriptParser.parse("let x =\nlet y =")
        // Two incomplete bindings — both should produce diagnostics.
        #expect(result.errors.count >= 2)
    }

    @Test func successfulProgramStillRuns() async throws {
        // After diagnostics machinery is in place, well-formed code still works.
        let interp = Interpreter()
        #expect(try await interp.eval("2 * 21") == .int(42))
    }
}
