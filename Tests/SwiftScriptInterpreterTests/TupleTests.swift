import Testing
@testable import SwiftScriptInterpreter

@Suite("Tuples")
struct TupleTests {
    @Test func tupleLiteral() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("(3, 4)")
        #expect(r == .tuple([.int(3), .int(4)]))
    }

    @Test func tupleLiteralDescription() async throws {
        let interp = Interpreter()
        // Matches Swift's default printing.
        let r = try await interp.eval("let p = (3, 4); p")
        #expect(r.description == "(3, 4)")
    }

    @Test func tupleElementAccessDot0() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("let p = (3, 4); p.0") == .int(3))
        #expect(try await interp.eval("let p = (3, 4); p.1") == .int(4))
    }

    @Test func tupleOutOfBounds() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("let p = (1, 2); p.5")
        }
    }

    @Test func tupleDestructuring() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("let (x, y) = (10, 20); x + y")
        #expect(r == .int(30))
    }

    @Test func tupleDestructureWithWildcard() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("let (_, y) = (99, 7); y")
        #expect(r == .int(7))
    }

    @Test func functionReturnsTuple() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func mm() -> (Int, Int) { return (3, 4) }
            let p = mm()
            p.0 + p.1
            """)
        #expect(r == .int(7))
    }

    @Test func functionReturnsTupleImplicit() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func mm() -> (Int, Int) { (3, 4) }
            let (a, b) = mm()
            a * b
            """)
        #expect(r == .int(12))
    }

    @Test func minMaxRealistic() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func minMax(_ xs: [Int]) -> (Int, Int) {
                var lo = xs[0]
                var hi = xs[0]
                for x in xs {
                    if x < lo { lo = x }
                    if x > hi { hi = x }
                }
                return (lo, hi)
            }
            minMax([5, 2, 8, 1, 9, 3])
            """)
        #expect(r == .tuple([.int(1), .int(9)]))
    }

    @Test func emptyTupleIsVoid() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("()")
        #expect(r == .void)
    }
}
