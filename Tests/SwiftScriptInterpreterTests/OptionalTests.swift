import Testing
@testable import SwiftScriptInterpreter

@Suite("Optional creation")
struct OptionalCreationTests {
    @Test func intStringReturnsOptional() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Int("42")"#) == .optional(.int(42)))
        #expect(try await interp.eval(#"Int("hi")"#) == .optional(nil))
    }

    @Test func doubleStringReturnsOptional() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Double("3.14")"#) == .optional(.double(3.14)))
        #expect(try await interp.eval(#"Double("nope")"#) == .optional(nil))
    }

    @Test func intNumericStaysNonOptional() async throws {
        let interp = Interpreter()
        // Int(Double) and Int(Int) still return Int (matches Swift).
        #expect(try await interp.eval("Int(3.7)") == .int(3))
        #expect(try await interp.eval("Int(5)")   == .int(5))
    }

    @Test func arrayFirstLastAreOptional() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[10, 20, 30].first") == .optional(.int(10)))
        #expect(try await interp.eval("[10, 20, 30].last")  == .optional(.int(30)))
        #expect(try await interp.eval("[].first") == .optional(nil))
    }

    @Test func stringFirstIsOptional() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#""hi".first"#) == .optional(.string("h")))
        #expect(try await interp.eval(#""".first"#)   == .optional(nil))
    }
}

@Suite("Force unwrap")
struct ForceUnwrapTests {
    @Test func unwrapSome() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Int("42")!"#) == .int(42))
    }

    @Test func unwrapNilThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval(#"Int("hi")!"#)
        }
    }

    @Test func unwrapInArithmetic() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Int("10")! + Int("32")!"#) == .int(42))
    }
}

@Suite("Nil coalescing")
struct NilCoalescingTests {
    @Test func nilUsesDefault() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Int("hi") ?? 0"#) == .int(0))
    }

    @Test func someUnwraps() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Int("42") ?? 0"#) == .int(42))
    }

    @Test func defaultIsLazy() async throws {
        let interp = Interpreter()
        // The right side would crash if it were evaluated (force-unwrap of nil),
        // but `??` doesn't evaluate it because the left is non-nil.
        #expect(try await interp.eval(#"Int("42") ?? Int("x")!"#) == .int(42))
    }

    @Test func chainedDefaults() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Int("a") ?? Int("b") ?? 99"#) == .int(99))
    }
}

@Suite("Optional chaining")
struct OptionalChainingTests {
    @Test func chainOnSomeAccessesProperty() async throws {
        let interp = Interpreter()
        // [10, 20, 30].first returns Int?; .description (~unsupported) — use isEmpty instead
        // Use a known property: arr.first then ?? to test chain semantics.
        let r = try await interp.eval(#"["a", "b"].first?.uppercased()"#)
        #expect(r == .optional(.string("A")))
    }

    @Test func chainOnNoneShortCircuits() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"[].first?.uppercased()"#)
        // Empty array .first is nil → whole chain is nil.
        #expect(r == .optional(nil))
    }

    @Test func chainCollapsesOptionalReturning() async throws {
        let interp = Interpreter()
        // `arr.first` returns Optional; in a chain it should NOT double-wrap.
        // Build: [["x", "y"]].first?.first?.uppercased()
        let r = try await interp.eval(#"[["x", "y"]].first?.first?.uppercased()"#)
        #expect(r == .optional(.string("X")))
    }

    @Test func chainNilCoalescePattern() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"[].first?.uppercased() ?? "empty""#)
        #expect(r == .string("empty"))
    }

    @Test func chainOnMethodCall() async throws {
        let interp = Interpreter()
        // Method call on the chain receiver.
        let r = try await interp.eval(#""hello".first?.uppercased()"#)
        #expect(r == .optional(.string("H")))
    }
}

@Suite("if let with real Optionals")
struct IfLetTests {
    @Test func ifLetBindsUnwrapped() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let raw = "42"
            if let n = Int(raw) {
                "got \(n)"
            } else {
                "no"
            }
            """#)
        #expect(r == .string("got 42"))
    }

    @Test func ifLetBranchOnNil() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            if let n = Int("nope") {
                "got \(n)"
            } else {
                "missing"
            }
            """#)
        #expect(r == .string("missing"))
    }

    @Test func guardLetReturnsOnNil() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func parseDouble(_ s: String) -> Double {
                guard let d = Double(s) else { return -1.0 }
                return d * 2.0
            }
            parseDouble("3.5")
            """#)
        #expect(r == .double(7.0))
    }

    @Test func guardLetFailureReturnsDefault() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func parseDouble(_ s: String) -> Double {
                guard let d = Double(s) else { return -1.0 }
                return d * 2.0
            }
            parseDouble("nope")
            """#)
        #expect(r == .double(-1.0))
    }
}
