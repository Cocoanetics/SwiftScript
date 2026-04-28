import Testing
@testable import SwiftScriptInterpreter

@Suite("Booleans")
struct BooleanTests {
    @Test func andShortCircuits() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var ran = false
            func sideEffect() -> Bool { ran = true; return true }
            let _ = false && sideEffect()
            ran
            """)
        #expect(r == .bool(false))
    }

    @Test func orShortCircuits() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var ran = false
            func sideEffect() -> Bool { ran = true; return true }
            let _ = true || sideEffect()
            ran
            """)
        #expect(r == .bool(false))
    }

    @Test func boolFromStringTrue() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"Bool("true")"#)  == .optional(.bool(true)))
        #expect(try await interp.eval(#"Bool("false")"#) == .optional(.bool(false)))
        #expect(try await interp.eval(#"Bool("yes")"#)   == .optional(nil))
    }

    @Test func toggleVar() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var b = true
            b.toggle()
            b
            """)
        #expect(r == .bool(false))
    }

    @Test func toggleOnLetThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("let b = true\nb.toggle()")
        }
    }

    @Test func toggleOnNonBoolThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("var x = 1\nx.toggle()")
        }
    }

    @Test func allSatisfyTrue() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[2, 4, 6, 8].allSatisfy { $0 % 2 == 0 }") == .bool(true))
    }

    @Test func allSatisfyFalse() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[2, 4, 5, 8].allSatisfy { $0 % 2 == 0 }") == .bool(false))
    }

    @Test func deMorganIdentity() async throws {
        // !(a && b) == (!a || !b) — for all 4 combinations.
        let interp = Interpreter()
        let r = try await interp.eval("""
            func check(_ a: Bool, _ b: Bool) -> Bool {
                return !(a && b) == (!a || !b)
            }
            check(true, true) && check(true, false) && check(false, true) && check(false, false)
            """)
        #expect(r == .bool(true))
    }

    @Test func wildcardLetDiscardsValue() async throws {
        // Just verifying the wildcard pattern parses and evaluates without
        // binding anything — the side-effect "var x = 0" should still run.
        let interp = Interpreter()
        let r = try await interp.eval("""
            var x = 0
            let _ = { x = 42 }()
            x
            """)
        #expect(r == .int(42))
    }

    @Test func ifLetWithBoolInit() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            if let b = Bool("true") {
                "got \(b)"
            } else {
                "nope"
            }
            """#)
        #expect(r == .string("got true"))
    }
}
