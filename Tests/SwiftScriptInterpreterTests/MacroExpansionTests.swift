import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Issue #14, freestanding half: `#name(args…)` dispatches to a
/// host-registered handler that receives each argument evaluated *and*
/// as source text — the property that separates a macro from a
/// function. `#expect` records and continues; `#require` throws; an
/// unregistered `#name` stays a hard error.
@Suite("Freestanding macro expansion (issue #14)")
struct MacroExpansionTests {

    // MARK: - Dispatch and argument shape

    @Test func handlerReceivesValuesAndSourceText() async throws {
        let interp = Interpreter()
        var seen: [(String?, Value, String)] = []
        interp.registerMacro("probe") { args in
            for a in args { seen.append((a.label, a.value, a.sourceText)) }
            return .int(args.count)
        }
        let r = try await interp.eval("""
            let a = 1
            #probe(a + 1 == 3, tag: "x")
            """)
        #expect(r == .int(2))
        #expect(seen.count == 2)
        #expect(seen[0].0 == nil)
        #expect(seen[0].1 == .bool(false))
        #expect(seen[0].2 == "a + 1 == 3")
        #expect(seen[1].0 == "tag")
        #expect(seen[1].1 == .string("x"))
        #expect(seen[1].2 == #""x""#)
    }

    @Test func macroWorksInFunctionBodyAndBinding() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerMacro("require") { args in
            // Swift Testing's unwrapping form: `.optional(x)` unwraps,
            // nil throws, bare values pass through.
            if case .optional(let inner) = args[0].value {
                guard let inner else {
                    throw RuntimeError.invalid("Expectation failed: \(args[0].sourceText)")
                }
                return inner
            }
            return args[0].value
        }
        _ = try await interp.eval("""
            func f() throws -> Int {
                let n = try #require(Int("21"))
                return n * 2
            }
            print(try f())
            """)
        #expect(out == "42\n")
    }

    @Test func throwingMacroIsCatchableAndTryQuestionSuppresses() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerMacro("require") { args in
            throw RuntimeError.invalid("Expectation failed: \(args[0].sourceText)")
        }
        _ = try await interp.eval("""
            do {
                let _ = try #require(false)
                print("no throw")
            } catch {
                print("caught:", error)
            }
            let quiet = try? #require(false)
            print(quiet == nil)
            """)
        #expect(out == "caught: Expectation failed: false\ntrue\n")
    }

    @Test func recordAndContinueShape() async throws {
        // `#expect` semantics: the handler records, returns `.void`,
        // and the script keeps running — one run surfaces every issue.
        var issues: [String] = []
        let interp = Interpreter()
        interp.registerMacro("expect") { args in
            if args[0].value == .bool(false) {
                issues.append("Expectation failed: \(args[0].sourceText)")
            }
            return .void
        }
        _ = try await interp.eval("""
            #expect(1 + 1 == 3)
            #expect(2 == 2)
            #expect("a" == "b")
            """)
        #expect(issues == [
            "Expectation failed: 1 + 1 == 3",
            #"Expectation failed: "a" == "b""#,
        ])
    }

    @Test func leadingDotArgumentDefersToHandler() async throws {
        let interp = Interpreter()
        var got: Value? = nil
        interp.registerMacro("probe") { args in
            got = args[0].value
            return .void
        }
        _ = try await interp.eval("#probe(.someCase)")
        #expect(got == .enumValue(typeName: "", caseName: "someCase", associatedValues: []))
    }

    @Test func callShapedLeadingDotArgumentDefersToHandler() async throws {
        // `.caseName(1)` — call-shaped implicit member, same deferral
        // as the bare form (and as attribute arguments).
        let interp = Interpreter()
        var got: Value? = nil
        interp.registerMacro("probe") { args in
            got = args[0].value
            return .void
        }
        _ = try await interp.eval("#probe(.caseName(1))")
        #expect(got == .enumValue(
            typeName: "", caseName: "caseName", associatedValues: [.int(1)]
        ))
    }

    @Test func trailingClosureFoldsIntoArguments() async throws {
        let interp = Interpreter()
        var sourceTexts: [String] = []
        var closureValue: Value? = nil
        interp.registerMacro("run") { args in
            sourceTexts = args.map(\.sourceText)
            closureValue = args.last?.value
            return .void
        }
        _ = try await interp.eval("""
            #run(1) { 40 + 2 }
            """)
        #expect(sourceTexts.count == 2)
        #expect(sourceTexts[1] == "{ 40 + 2 }")
        if case .function? = closureValue {} else {
            Issue.record("trailing closure should arrive as a .function value")
        }
    }

    // MARK: - Hard errors

    @Test func unregisteredMacroIsHardError() async throws {
        let interp = Interpreter()
        do {
            _ = try await interp.eval("#expect(1 == 1)")
            Issue.record("expected a hard error")
        } catch let err as RuntimeError {
            #expect(err.description == "no macro named 'expect'")
        }
    }

    @Test func genericArgumentClauseIsUnsupported() async throws {
        let interp = Interpreter()
        interp.registerMacro("probe") { _ in .void }
        do {
            _ = try await interp.eval("#probe<Int>(1)")
            Issue.record("expected a hard error")
        } catch let err as RuntimeError {
            #expect(err.description.contains("generic arguments on macro '#probe'"))
        }
    }

    @Test func memberPositionMacroIsLoudError() async throws {
        // Previously `struct S { #foo("x") }` silently dropped the
        // member — the exact silent divergence the preflight exists to
        // prevent. Now it errors loudly.
        let interp = Interpreter()
        do {
            _ = try await interp.eval("""
                struct S { #foo("x") }
                """)
            Issue.record("expected a hard error")
        } catch let err as RuntimeError {
            #expect(err.description.contains("freestanding macro '#foo' in member position"))
        }
    }
}
