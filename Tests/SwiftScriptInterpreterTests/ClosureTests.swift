import Testing
@testable import SwiftScriptInterpreter

@Suite("Closures")
struct ClosureTests {
    @Test func explicitTypedClosure() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let double = { (x: Int) in x * 2 }
            double(7)
            """)
        #expect(r == .int(14))
    }

    @Test func closureWithReturnType() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let inc = { (x: Int) -> Int in return x + 1 }
            inc(10)
            """)
        #expect(r == .int(11))
    }

    @Test func shorthandArgs() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let add: (Int, Int) -> Int = { $0 + $1 }
            add(3, 4)
            """)
        #expect(r == .int(7))
    }

    @Test func trailingClosureOnUserFunc() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func twice(_ f: (Int) -> Int) -> Int { f(f(2)) }
            twice { $0 + 1 }
            """)
        #expect(r == .int(4))
    }

    @Test func capturedLet() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let factor = 3
            let scale = { (x: Int) in x * factor }
            scale(5)
            """)
        #expect(r == .int(15))
    }

    @Test func mutationOfCapturedVar() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var n = 0
            let bump = { n += 1 }
            bump()
            bump()
            n
            """)
        #expect(r == .int(2))
    }

    @Test func multiStatementClosure() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let f = { (x: Int) -> Int in
                let y = x * 2
                return y + 1
            }
            f(5)
            """)
        #expect(r == .int(11))
    }

    @Test func implicitReturnSingleExpression() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let f: (Int) -> Int = { $0 * $0 }
            f(6)
            """)
        #expect(r == .int(36))
    }

    @Test func closureAsArgumentExplicit() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func apply(_ f: (Int) -> Int, to x: Int) -> Int { f(x) }
            apply({ $0 + 100 }, to: 5)
            """)
        #expect(r == .int(105))
    }
}
