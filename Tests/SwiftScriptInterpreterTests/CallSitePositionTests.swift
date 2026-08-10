import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Issues #15/#16: errors and recorded failures can name their source
/// line.
///
/// #15 — an error raised inside a bridge (`RuntimeError` or raw host
/// error) is stamped with the offset of the call that invoked the
/// bridge, so an uncaught failure renders with the `swiftc`-style
/// file:line:col header and caret instead of a bare `error:` line.
///
/// #16 — a builtin can read `currentCallOffset` while it runs, so an
/// assertion-shaped global that *records* a failure (Swift Testing /
/// XCTest semantics — record and continue, nothing thrown) can capture
/// the call site and later render it via `renderSourceContext(at:message:)`.
@Suite("Positioned errors (issues #15/#16)")
struct CallSitePositionTests {

    /// Bridge fixture matching the embedder pattern from issue #15: a
    /// method that signals failure by throwing a `RuntimeError`, and one
    /// that throws a raw host error.
    private struct HostFailure: Error {}
    private struct FlakyModule: BuiltinModule {
        let name = "Flaky"
        func register(into i: Interpreter) {
            i.bridges["init Widget()"] = .`init` { _ in
                .opaque(typeName: "Widget", value: "w")
            }
            i.bridges["func Widget.mustExist()"] = .method { _, _ in
                throw RuntimeError.invalid("no element matches buttons[\"missing\"]")
            }
            i.bridges["func Widget.explode()"] = .method { _, _ in
                throw HostFailure()
            }
        }
    }

    private func makeFlakyInterpreter() -> Interpreter {
        let interp = Interpreter(output: { _ in })
        interp.registerOnImport("Flaky", module: FlakyModule())
        return interp
    }

    // MARK: - Issue #15: bridge errors carry the call site

    @Test func uncaughtBridgeRuntimeErrorRendersWithPosition() async throws {
        let interp = makeFlakyInterpreter()
        do {
            _ = try await interp.eval(#"""
                import Flaky
                let w = Widget()
                w.mustExist()
                """#, fileName: "check.swift")
            Issue.record("expected the bridge error to end the script")
        } catch {
            let script = try #require(error as? ScriptError)
            #expect(script.offset != nil)
            let rendered = interp.renderRuntimeError(error)
            // Anchored on the member name, where stock Swift points
            // member diagnostics — not on the receiver.
            #expect(rendered.contains(
                "check.swift:3:3: error: no element matches buttons[\"missing\"]"))
            #expect(rendered.contains("`- error: no element matches"))
        }
    }

    @Test func lineBrokenChainBlamesTheFailingMemberLine() async throws {
        // Conventional XCUITest formatting: each postfix step on its own
        // line. The caret must land on the failing member's line, not on
        // the receiver at the start of the chain.
        let interp = makeFlakyInterpreter()
        do {
            _ = try await interp.eval(#"""
                import Flaky
                let w = Widget()
                w
                    .mustExist()
                """#, fileName: "chain.swift")
            Issue.record("expected the bridge error to end the script")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("chain.swift:4:6: error: no element matches"))
        }
    }

    @Test func boxedRuntimeErrorCarriesThePositionToo() async throws {
        // A host digging the RuntimeError back out of the opaque payload
        // can ask it for the offset directly.
        let interp = makeFlakyInterpreter()
        do {
            _ = try await interp.eval(#"""
                import Flaky
                Widget().mustExist()
                """#, fileName: "check.swift")
            Issue.record("expected the bridge error to end the script")
        } catch {
            let script = try #require(error as? ScriptError)
            let runtime = try #require(script.hostError as? RuntimeError)
            #expect(runtime.offset == script.offset)
            #expect(runtime.description == "no element matches buttons[\"missing\"]")
            // The positioned error still matches its case pattern —
            // position is a payload, not a wrapper that changes what
            // the error is.
            guard case .invalid(let message, let at) = runtime else {
                Issue.record("positioned error no longer matches .invalid")
                return
            }
            #expect(message == "no element matches buttons[\"missing\"]")
            #expect(at == script.offset)
        }
    }

    @Test func positionedDivisionByZeroStillMatchesItsCase() async throws {
        let interp = Interpreter(output: { _ in })
        do {
            _ = try await interp.eval("1 / 0", fileName: "check.swift")
            Issue.record("expected the division to trap")
        } catch {
            let runtime = try #require(error as? RuntimeError)
            #expect(runtime.offset != nil)
            guard case .divisionByZero = runtime else {
                Issue.record("positioned error no longer matches .divisionByZero")
                return
            }
        }
    }

    @Test func uncaughtHostErrorRendersWithPosition() async throws {
        // Not a RuntimeError at all — the raw host error from a bridge
        // gets the same treatment (the "worth considering" case in #15).
        let interp = makeFlakyInterpreter()
        do {
            _ = try await interp.eval(#"""
                import Flaky
                let w = Widget()
                w.explode()
                """#, fileName: "check.swift")
            Issue.record("expected the host error to end the script")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("check.swift:3:3: error:"))
            #expect(rendered.contains("HostFailure"))
        }
    }

    @Test func bridgeErrorRemainsCatchableWithSameDescription() async throws {
        // Positioning must not disturb the issue-#12/#13 contract: the
        // script-side catch still fires and the message is unchanged.
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerOnImport("Flaky", module: FlakyModule())
        _ = try await interp.eval(#"""
            import Flaky
            do {
                Widget().mustExist()
            } catch {
                print("recovered:", error)
            }
            """#)
        #expect(out == "recovered: no element matches buttons[\"missing\"]\n")
    }

    @Test func generatedBridgeSubscriptErrorRendersWithPosition() async throws {
        // The self-wrapping path: generated Foundation bridges box their
        // errors into a ScriptError *inside* the bridge body; the wrapper
        // is stamped as it crosses the bridge boundary.
        let interp = Interpreter(output: { _ in })
        do {
            _ = try await interp.eval(#"""
                import Foundation
                let d = Data([1, 2])
                let x = d[99]
                """#, fileName: "check.swift")
            Issue.record("expected the out-of-bounds error to end the script")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            // Anchored on the subscript's opening bracket.
            #expect(rendered.contains("check.swift:3:10: error: Data index 99 out of bounds"))
        }
    }

    @Test func uncaughtScriptThrowRendersWithPosition() async throws {
        let interp = Interpreter(output: { _ in })
        do {
            _ = try await interp.eval(#"""
                enum E: Error { case bad }
                throw E.bad
                """#, fileName: "check.swift")
            Issue.record("expected the script throw to end the script")
        } catch {
            let script = try #require(error as? ScriptError)
            #expect(script.caseName == "bad")
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("check.swift:2:1: error: E.bad"))
        }
    }

    @Test func divisionByZeroRendersWithPosition() async throws {
        let interp = Interpreter(output: { _ in })
        do {
            _ = try await interp.eval(#"""
                let a = 10
                let b = 0
                let c = a / b
                """#, fileName: "check.swift")
            Issue.record("expected the division to trap")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("check.swift:3:9: error: division by zero"))
        }
    }

    @Test func fatalErrorRendersWithPosition() async throws {
        let interp = Interpreter(output: { _ in })
        do {
            _ = try await interp.eval(#"""
                import Foundation
                fatalError("boom")
                """#, fileName: "check.swift")
            Issue.record("expected fatalError to end the script")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("check.swift:2:1: error: fatal error: boom"))
        }
    }

    @Test func preciseOffsetsAreNotOverwritten() async throws {
        // `unknownIdentifier` knows its own (tighter) position; the
        // stamping layers must leave it alone.
        let interp = Interpreter(output: { _ in })
        do {
            _ = try await interp.eval(#"""
                let x = 1
                let y = undefinedThing + x
                """#, fileName: "check.swift")
            Issue.record("expected unknown identifier to end the script")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains(
                "check.swift:2:9: error: cannot find 'undefinedThing' in scope"))
        }
    }

    // MARK: - Registered globals sit on the same boundary

    @Test func hostErrorFromRegisteredGlobalRendersWithPosition() async throws {
        // A custom host error thrown from a `registerGlobal` closure is
        // wrapped and stamped like a bridge error would be — not left to
        // escape raw with no position.
        let interp = Interpreter(output: { _ in })
        interp.registerGlobal(name: "flaky") { _ in throw HostFailure() }
        do {
            _ = try await interp.eval(#"""
                let x = 1
                flaky()
                """#, fileName: "check.swift")
            Issue.record("expected the host error to end the script")
        } catch {
            let script = try #require(error as? ScriptError)
            #expect(script.offset != nil)
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("check.swift:2:1: error:"))
            #expect(rendered.contains("HostFailure"))
        }
    }

    @Test func hostErrorFromRegisteredGlobalIsCatchable() async throws {
        // Same catchability contract as a bridge body (#13): a host
        // error is a recoverable failure, not an interpreter trap.
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerGlobal(name: "flaky") { _ in throw HostFailure() }
        _ = try await interp.eval(#"""
            do {
                flaky()
            } catch {
                print("recovered:", error)
            }
            """#)
        #expect(out.contains("recovered:"))
        #expect(out.contains("HostFailure"))
    }

    @Test func runtimeErrorFromRegisteredGlobalStaysFatal() async throws {
        // The trap side of the boundary is unchanged: `RuntimeError`
        // from a global (the `fatalError` / `precondition` shape) still
        // terminates the script past any `catch` — but positioned now.
        let interp = Interpreter(output: { _ in })
        interp.registerGlobal(name: "trap") { _ in
            throw RuntimeError.invalid("deliberate trap")
        }
        do {
            _ = try await interp.eval(#"""
                do {
                    trap()
                } catch {
                    print("should not catch a trap")
                }
                """#, fileName: "check.swift")
            Issue.record("expected the trap to end the script")
        } catch {
            let rendered = interp.renderRuntimeError(error)
            #expect(rendered.contains("check.swift:2:5: error: deliberate trap"))
        }
    }

    // MARK: - Host control-flow sentinels bypass script catch

    /// The Loupe regression: a host that throws a sentinel as control
    /// flow (XCTSkip-style) must always get it back — script `catch`
    /// and `try?` must not be able to swallow it.
    private struct SkipSentinel: Error, ScriptUncatchableError {}

    @Test func uncatchableSentinelFromGlobalReachesTheHostIntact() async throws {
        let interp = Interpreter(output: { _ in })
        interp.registerGlobal(name: "skipRun") { _ in throw SkipSentinel() }
        do {
            _ = try await interp.eval(#"""
                do {
                    let x = try? skipRun()
                } catch {
                    print("script must not see the sentinel")
                }
                """#)
            Issue.record("expected the sentinel to end the script")
        } catch {
            // Raw and typed — not boxed into a ScriptError.
            #expect(error is SkipSentinel)
        }
    }

    @Test func uncatchableSentinelFromBridgeReachesTheHostIntact() async throws {
        let interp = Interpreter(output: { _ in })
        struct SkipModule: BuiltinModule {
            let name = "Skip"
            func register(into i: Interpreter) {
                i.bridges["init Gate()"] = .`init` { _ in
                    .opaque(typeName: "Gate", value: "g")
                }
                i.bridges["func Gate.check()"] = .method { _, _ in
                    throw SkipSentinel()
                }
            }
        }
        interp.registerOnImport("Skip", module: SkipModule())
        do {
            _ = try await interp.eval(#"""
                import Skip
                do {
                    Gate().check()
                } catch {
                    print("script must not see the sentinel")
                }
                """#)
            Issue.record("expected the sentinel to end the script")
        } catch {
            #expect(error is SkipSentinel)
        }
    }

    // MARK: - Issue #16: the call site is visible to builtins

    @Test func recordedAssertionFailureNamesItsLine() async throws {
        // The Swift Testing model: a failed expectation records and
        // continues. Nothing is thrown, so the position must come from
        // `currentCallOffset` read while the builtin runs.
        var issues: [(offset: Int?, message: String)] = []
        let interp = Interpreter(output: { _ in })
        interp.registerGlobal(name: "expectTrue") { args in
            guard case .bool(let ok) = args.first else {
                throw RuntimeError.invalid("expectTrue: first argument must be Bool")
            }
            if !ok {
                var message = "expectation failed"
                if args.count >= 2, case .string(let s) = args[1] { message = s }
                issues.append((interp.currentCallOffset, message))
            }
            return .void
        }

        _ = try await interp.eval(#"""
            let ready = false
            expectTrue(true, "warmup")
            expectTrue(ready, "dashboard did not appear")
            expectTrue(false, "expected 7 rows, found 2")
            """#, fileName: "check.swift")

        // The run completed — both failures recorded, none thrown.
        #expect(issues.count == 2)

        let first = try #require(issues.first)
        let firstOffset = try #require(first.offset)
        let rendered = interp.renderSourceContext(at: firstOffset, message: first.message)
        #expect(rendered.contains("check.swift:3:1: error: dashboard did not appear"))
        #expect(rendered.contains("`- error: dashboard did not appear"))

        let second = try #require(issues.last)
        let secondOffset = try #require(second.offset)
        let renderedSecond = interp.renderSourceContext(
            at: secondOffset, message: second.message)
        #expect(renderedSecond.contains("check.swift:4:1: error: expected 7 rows, found 2"))
    }

    @Test func currentCallOffsetIsNilOutsideEvaluation() async throws {
        let interp = Interpreter(output: { _ in })
        #expect(interp.currentCallOffset == nil)
        _ = try await interp.eval("1 + 1")
        #expect(interp.currentCallOffset == nil)
    }

    @Test func renderSourceContextWithoutSourceFallsBack() {
        let interp = Interpreter(output: { _ in })
        #expect(interp.renderSourceContext(at: 0, message: "boom") == "error: boom\n")
    }

    @Test func renderSourceContextClampsOutOfRangeOffsets() async throws {
        let interp = Interpreter(output: { _ in })
        _ = try await interp.eval("let x = 1", fileName: "tiny.swift")
        // A junk offset must not crash the renderer.
        let rendered = interp.renderSourceContext(at: 999_999, message: "late failure")
        #expect(rendered.contains("error: late failure"))
    }
}
