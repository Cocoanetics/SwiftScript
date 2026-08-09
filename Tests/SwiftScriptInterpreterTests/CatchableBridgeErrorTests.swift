import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Issue #12: an error raised inside a bridge (a `RuntimeError`, or a
/// raw host error) is catchable by script `do`/`catch` and suppressed
/// by `try?`, the same as a script-side `throw` — while control-flow
/// signals (`return`/`break`/`continue`/`exit`) keep bypassing `catch`.
@Suite("Catchable bridge errors (issue #12)")
struct CatchableBridgeErrorTests {

    /// A bridge that signals a recoverable failure by throwing — the
    /// embedder pattern the issue is about (an element that isn't there
    /// yet, an I/O error worth retrying).
    private struct FlakyModule: BuiltinModule {
        let name = "Flaky"
        func register(into i: Interpreter) {
            i.bridges["init Widget()"] = .`init` { _ in
                .opaque(typeName: "Widget", value: "w")
            }
            i.bridges["func Widget.mustExist()"] = .method { _, _ in
                throw RuntimeError.invalid("element not found")
            }
        }
    }

    @Test func embedderBridgeThrowIsCaught() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerOnImport("Flaky", module: FlakyModule())
        _ = try await interp.eval(#"""
            import Flaky
            do {
                Widget().mustExist()
                print("no throw")
            } catch {
                print("recovered:", error)
            }
            """#)
        #expect(out == "recovered: element not found\n")
    }

    @Test func bridgeSubscriptErrorIsCaught() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        _ = try await interp.eval(#"""
            import Foundation
            do {
                let d = Data([1, 2])
                _ = d[99]
                print("no throw")
            } catch {
                print("recovered:", error)
            }
            """#)
        #expect(out == "recovered: Data index 99 out of bounds (0..<2)\n")
    }

    @Test func tryQuestionSuppressesBridgeError() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            func boom() throws -> Int {
                let d = Data([1])
                return d[42]        // bridge RuntimeError
            }
            (try? boom()) ?? -1
            """#)
        #expect(r == .int(-1))
    }

    @Test func uncaughtBridgeErrorStillPropagates() async throws {
        // No matching clause → the original error ends the script.
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                Data([1])[5]
                """#)
        }
    }

    @Test func typedCatchClauseFallsThroughToDefault() async throws {
        // A bridge error is an opaque `Error`, so a script-enum typed
        // clause doesn't match — the default clause binds it.
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        _ = try await interp.eval(#"""
            import Foundation
            enum E: Error { case specific }
            do {
                _ = Data([1])[5]
            } catch E.specific {
                print("specific")
            } catch {
                print("default")
            }
            """#)
        #expect(out == "default\n")
    }

    // MARK: - Control-flow signals still bypass catch

    @Test func returnBypassesCatch() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func f() -> Int {
                do {
                    return 42
                } catch {
                    return -1
                }
            }
            f()
            """#)
        #expect(r == .int(42))
    }

    @Test func breakAndContinueBypassCatch() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        _ = try await interp.eval(#"""
            var kept = 0
            for i in 0..<5 {
                do {
                    if i == 1 { continue }
                    if i == 3 { break }
                    kept += i
                } catch {
                    print("caught control flow?!")
                }
            }
            print(kept)
            """#)
        #expect(out == "2\n")   // i=0 (+0) and i=2 (+2); 1 continued, 3 broke
    }

    @Test func exitBypassesCatch() async throws {
        // `exit(_:)` raises `ScriptExit`, which must terminate the
        // script rather than be swept up by an enclosing catch.
        let interp = Interpreter()
        let status = try await interp.evalScript(#"""
            import Foundation
            do {
                exit(7)
            } catch {
                print("should not catch exit")
            }
            """#)
        #expect(status.code == 7)
    }

    // MARK: - Interpreter traps and programming errors stay fatal

    /// These are raised by the interpreter itself — outside any bridge
    /// body — so wrapping bridge errors must not make them catchable.
    /// In stock Swift each is an uncatchable trap or a compile error.
    private func expectUncatchable(_ source: String) async {
        let interp = Interpreter(output: { _ in })
        var caughtInScript = false
        do {
            _ = try await interp.eval("""
                \(source)
                """)
        } catch {
            // The error propagates to the host — it was NOT swallowed
            // by the script's own catch.
            caughtInScript = false
            _ = caughtInScript
            return
        }
        Issue.record("expected the error to terminate the script, but it completed")
    }

    @Test func fatalErrorNotCatchable() async {
        await expectUncatchable(#"""
            import Foundation
            do { fatalError("boom") } catch { print("caught fatal") }
            """#)
    }

    @Test func preconditionFailureNotCatchable() async {
        await expectUncatchable(#"""
            import Foundation
            do { precondition(false, "nope") } catch { print("caught precondition") }
            """#)
    }

    @Test func divisionByZeroNotCatchable() async {
        await expectUncatchable(#"""
            func f(_ a: Int, _ b: Int) -> Int { a / b }
            do { _ = f(1, 0) } catch { print("caught division") }
            """#)
    }

    @Test func undefinedIdentifierNotCatchable() async {
        await expectUncatchable(#"""
            do { let _ = someUndefinedThing() } catch { print("caught undefined") }
            """#)
    }

    @Test func noSuchMemberNotCatchable() async {
        await expectUncatchable(#"""
            do { let _ = 5.hasPrefix("a") } catch { print("caught nsm") }
            """#)
    }

    @Test func tryQuestionDoesNotSuppressTrap() async {
        // `try?` suppresses a *thrown* error, but never a trap.
        let interp = Interpreter(output: { _ in })
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                func f(_ a: Int, _ b: Int) -> Int { a / b }
                let r = (try? f(1, 0)) ?? -1
                _ = r
                """#)
        }
    }

    // MARK: - Script throw still works unchanged

    @Test func scriptThrowStillCatchableByPattern() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        _ = try await interp.eval(#"""
            enum E: Error { case parse(String) }
            func f() throws -> Int { throw E.parse("oops") }
            do {
                _ = try f()
            } catch E.parse(let m) {
                print("err:", m)
            } catch {
                print("other")
            }
            """#)
        #expect(out == "err: oops\n")
    }
}
