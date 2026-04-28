import Testing
@testable import SwiftScriptInterpreter

@Suite("Numeric coercion")
struct NumericCoercionTests {
    // MARK: - Let/var binding

    @Test func letDoubleAcceptsIntegerLiteral() async throws {
        let interp = Interpreter()
        // Swift: `let x: Double = 5` → 5.0
        let r = try await interp.eval("let x: Double = 5\nx")
        #expect(r == .double(5.0))
    }

    @Test func letIntRejectsFloatLiteral() async throws {
        let interp = Interpreter()
        // Swift: `let x: Int = 5.0` → compile error.
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("let x: Int = 5.0")
        }
    }

    @Test func letDoubleAcceptsLiteralExpression() async throws {
        let interp = Interpreter()
        // Swift: `let d: Double = 5 + 1` → 6.0 (whole expression is polymorphic)
        let r = try await interp.eval("let d: Double = 5 + 1\nd")
        #expect(r == .double(6.0))
    }

    @Test func letDoubleAcceptsMixedLiteralExpression() async throws {
        let interp = Interpreter()
        // Swift: `let d: Double = 1 + 2.0` → 3.0
        let r = try await interp.eval("let d: Double = 1 + 2.0\nd")
        #expect(r == .double(3.0))
    }

    @Test func letDoubleRejectsIntVariable() async throws {
        let interp = Interpreter()
        // Swift: `let i = 5; let x: Double = i` → compile error
        // (need explicit `Double(i)`).
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                let i = 5
                let x: Double = i
                """)
        }
    }

    @Test func letDoubleAcceptsExplicitConversion() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let i = 5
            let x: Double = Double(i)
            x
            """)
        #expect(r == .double(5.0))
    }

    @Test func letOptionalWrapsInteger() async throws {
        let interp = Interpreter()
        // Swift: `let x: Int? = 5` → Optional(5)
        let r = try await interp.eval("let x: Int? = 5\nx")
        #expect(r == .optional(.int(5)))
    }

    // MARK: - Function calls

    @Test func functionAcceptsIntegerLiteralForDoubleParam() async throws {
        let interp = Interpreter()
        // Swift: f(5) where f takes Double → 5 polymorphs to 5.0.
        let r = try await interp.eval("""
            func f(_ n: Double) -> Double { n / 2 }
            f(10)
            """)
        #expect(r == .double(5.0))
    }

    @Test func functionRejectsIntVariableForDoubleParam() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                func f(_ n: Double) { print(n) }
                let i = 5
                f(i)
                """)
        }
    }

    // MARK: - Binary operators

    @Test func mixedLiteralsCombineAsDouble() async throws {
        let interp = Interpreter()
        // Both literals — `1 + 2.0` adapts and is Double.
        let r = try await interp.eval("1 + 2.0")
        #expect(r == .double(3.0))
    }

    @Test func mixedVariableAndLiteralDoubleThrows() async throws {
        let interp = Interpreter()
        // i is an Int variable; 2.0 is a Double literal. Swift refuses.
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                let i = 1
                i + 2.0
                """)
        }
    }

    @Test func mixedDoubleVariableAndIntLiteralIsAllowed() async throws {
        let interp = Interpreter()
        // d is a Double variable; 2 is an Int literal — literal adapts.
        let r = try await interp.eval("""
            let d = 1.5
            d + 2
            """)
        #expect(r == .double(3.5))
    }

    // MARK: - Return values

    @Test func implicitReturnCoercesIntegerLiteral() async throws {
        let interp = Interpreter()
        // Swift: `func f() -> Double { 5 }` — 5 polymorphs to 5.0.
        let r = try await interp.eval("""
            func f() -> Double { 5 }
            f()
            """)
        #expect(r == .double(5.0))
    }

    @Test func explicitReturnCoercesIntegerLiteral() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func f() -> Double { return 5 }
            f()
            """)
        #expect(r == .double(5.0))
    }

    @Test func returnRejectsIntVariableForDouble() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                func f() -> Double {
                    let i = 5
                    return i
                }
                f()
                """)
        }
    }

    // MARK: - Pure-Int paths still match Swift

    @Test func intDivisionStillTruncates() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("1 / 2") == .int(0))
    }

    @Test func mixedLiteralDivisionPromotes() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("1 / 2.0") == .double(0.5))
    }
}
