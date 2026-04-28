import Testing
@testable import SwiftScriptInterpreter

@Suite("Arithmetic")
struct ArithmeticTests {
    @Test func integerAddition() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("1 + 2")
        #expect(r == .int(3))
    }

    @Test func operatorPrecedence() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("1 + 2 * 3")
        #expect(r == .int(7))
    }

    @Test func parensOverridePrecedence() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("(1 + 2) * 3")
        #expect(r == .int(9))
    }

    @Test func intDoublePromotion() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("3 + 0.5")
        #expect(r == .double(3.5))
    }

    @Test func unaryMinus() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("-(2 + 3)")
        #expect(r == .int(-5))
    }

    @Test func integerDivisionTruncates() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("7 / 2")
        #expect(r == .int(3))
    }

    @Test func divisionByZeroThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("1 / 0")
        }
    }

    @Test func remainder() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("10 % 3")
        #expect(r == .int(1))
    }

    @Test func comparisons() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("3 < 4") == .bool(true))
        #expect(try await interp.eval("3 == 3") == .bool(true))
        #expect(try await interp.eval("3.0 != 3") == .bool(false))
    }

    @Test func booleanShortCircuit() async throws {
        let interp = Interpreter()
        // If the rhs were evaluated, the unknown identifier `bogus`
        // would throw — short-circuit avoids that.
        #expect(try await interp.eval("false && bogus") == .bool(false))
        #expect(try await interp.eval("true || bogus")  == .bool(true))
    }
}

