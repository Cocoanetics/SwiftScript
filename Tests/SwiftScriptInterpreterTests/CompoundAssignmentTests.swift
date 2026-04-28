import Testing
@testable import SwiftScriptInterpreter

@Suite("Compound assignment")
struct CompoundAssignmentTests {
    @Test func intPlusEquals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var n = 5\nn += 3\nn")
        #expect(r == .int(8))
    }

    @Test func intMinusEquals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var n = 5\nn -= 2\nn")
        #expect(r == .int(3))
    }

    @Test func intMultiplyEquals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var n = 5\nn *= 4\nn")
        #expect(r == .int(20))
    }

    @Test func intDivideEqualsTruncates() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var n = 7\nn /= 2\nn")
        #expect(r == .int(3))
    }

    @Test func intModEquals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var n = 17\nn %= 5\nn")
        #expect(r == .int(2))
    }

    @Test func doubleMultiplyEquals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var d = 1.5\nd *= 2\nd")
        #expect(r == .double(3.0))
    }

    @Test func doublePlusEqualsIntegerLiteral() async throws {
        let interp = Interpreter()
        // Polymorphic int literal adapts to Double — same as direct binding.
        let r = try await interp.eval("var d: Double = 2.5\nd += 1\nd")
        #expect(r == .double(3.5))
    }

    @Test func compoundOnLetThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("let x = 5\nx += 1")
        }
    }

    @Test func intCompoundDoubleLiteralThrows() async throws {
        // Matches Swift: "cannot convert value of type 'Double' to expected
        // argument type 'Int'".
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("var i = 1\ni += 1.5")
        }
    }

    @Test func intCompoundDoubleVariableThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("var i = 1\nlet d = 0.5\ni += d")
        }
    }

    @Test func compoundOnUndeclaredThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("n2 += 1")
        }
    }

    @Test func stringPlusEquals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"var s = "hi"; s += " world"; s"#)
        #expect(r == .string("hi world"))
    }

    @Test func stringPlusEqualsInterpolation() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"var s = "n="; s += "\(1+2)"; s"#)
        #expect(r == .string("n=3"))
    }

    @Test func stringPlusEqualsIntThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval(#"var s = "x"; s += 1"#)
        }
    }

    @Test func loopAccumulator() async throws {
        // The motivating use case: imperative sum.
        let interp = Interpreter()
        let r = try await interp.eval("""
            var sum = 0
            for i in 1...10 {
                sum += i
            }
            sum
            """)
        #expect(r == .int(55))
    }
}
