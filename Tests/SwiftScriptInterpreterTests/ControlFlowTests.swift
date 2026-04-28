import Testing
@testable import SwiftScriptInterpreter

@Suite("Control flow")
struct ControlFlowTests {
    @Test func ifThenBranch() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var x = 0
            if 1 < 2 {
                x = 10
            } else {
                x = 20
            }
            x
            """)
        #expect(r == .int(10))
    }

    @Test func ifElseBranch() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var x = 0
            if 1 > 2 {
                x = 10
            } else {
                x = 20
            }
            x
            """)
        #expect(r == .int(20))
    }

    @Test func ifElseIfChain() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func sign(_ n: Int) -> Int {
                if n > 0 {
                    return 1
                } else if n < 0 {
                    return -1
                } else {
                    return 0
                }
            }
            sign(-7)
            """)
        #expect(r == .int(-1))
    }

    @Test func ifAsExpressionInLet() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let n = 5
            let kind = if n % 2 == 0 { "even" } else { "odd" }
            kind
            """)
        #expect(r == .string("odd"))
    }

    @Test func whileLoopComputesSum() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var i = 0
            var sum = 0
            while i < 10 {
                sum = sum + i
                i = i + 1
            }
            sum
            """)
        #expect(r == .int(45))
    }

    @Test func whileWithBreak() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var i = 0
            while true {
                if i == 3 {
                    break
                }
                i = i + 1
            }
            i
            """)
        #expect(r == .int(3))
    }

    @Test func forInHalfOpenRange() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var sum = 0
            for i in 0..<5 {
                sum = sum + i
            }
            sum
            """)
        #expect(r == .int(0 + 1 + 2 + 3 + 4))
    }

    @Test func forInClosedRange() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var sum = 0
            for i in 1...5 {
                sum = sum + i
            }
            sum
            """)
        #expect(r == .int(1 + 2 + 3 + 4 + 5))
    }

    @Test func forInWithContinue() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var sum = 0
            for i in 0..<10 {
                if i % 2 == 0 {
                    continue
                }
                sum = sum + i
            }
            sum
            """)
        #expect(r == .int(1 + 3 + 5 + 7 + 9))
    }

    @Test func nestedLoopsBreakInnerOnly() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var hits = 0
            for i in 0..<3 {
                for j in 0..<5 {
                    if j == 2 { break }
                    hits = hits + 1
                }
            }
            hits
            """)
        // i in 0..<3 × j in {0,1} = 6 hits.
        #expect(r == .int(6))
    }

    @Test func factorialUsesIfAndRecursion() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func fact(_ n: Int) -> Int {
                if n <= 1 { return 1 }
                return n * fact(n - 1)
            }
            fact(6)
            """)
        #expect(r == .int(720))
    }

    @Test func rangeLiteral() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("0..<3")  == .range(lower: 0, upper: 3, closed: false))
        #expect(try await interp.eval("1...10") == .range(lower: 1, upper: 10, closed: true))
    }
}

@Suite("Local functions")
struct LocalFunctionTests {
    @Test func localFunctionInsideFunction() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func compute(_ n: Int) -> Int {
                func double(_ k: Int) -> Int {
                    return k * 2
                }
                return double(n) + double(n + 1)
            }
            compute(3)
            """)
        // double(3) + double(4) = 6 + 8 = 14
        #expect(r == .int(14))
    }

    @Test func localFunctionCapturesOuterParameter() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func multiplier(_ factor: Int) -> Int {
                func apply(_ x: Int) -> Int {
                    return x * factor
                }
                return apply(7)
            }
            multiplier(3)
            """)
        #expect(r == .int(21))
    }

    @Test func recursiveLocalFunction() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func sumDownFrom(_ start: Int) -> Int {
                func go(_ n: Int) -> Int {
                    if n <= 0 { return 0 }
                    return n + go(n - 1)
                }
                return go(start)
            }
            sumDownFrom(5)
            """)
        // 5 + 4 + 3 + 2 + 1 = 15
        #expect(r == .int(15))
    }

    @Test func localShadowsOuter() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func square(_ n: Int) -> Int { return n * n }
            func outer() -> Int {
                func square(_ n: Int) -> Int { return n + 100 }
                return square(5)
            }
            outer()
            """)
        // outer's local `square` shadows the global one inside its body.
        #expect(r == .int(105))
    }
}
