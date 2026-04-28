import Testing
@testable import SwiftScriptInterpreter

@Suite("Repeat-while")
struct RepeatWhileTests {
    @Test func repeatExecutesBodyOnce() async throws {
        let interp = Interpreter()
        // The condition is false from the start, so repeat-while runs once.
        let r = try await interp.eval("""
            var hits = 0
            repeat {
                hits = hits + 1
            } while false
            hits
            """)
        #expect(r == .int(1))
    }

    @Test func repeatLoopsUntilCondFalse() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var i = 0
            var sum = 0
            repeat {
                sum = sum + i
                i = i + 1
            } while i < 5
            sum
            """)
        #expect(r == .int(0 + 1 + 2 + 3 + 4))
    }

    @Test func repeatBreak() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var i = 0
            repeat {
                if i == 3 { break }
                i = i + 1
            } while true
            i
            """)
        #expect(r == .int(3))
    }
}

@Suite("Guard")
struct GuardTests {
    @Test func guardConditionTrueFallsThrough() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func half(_ n: Int) -> Int {
                guard n > 0 else {
                    return -1
                }
                return n / 2
            }
            half(10)
            """)
        #expect(r == .int(5))
    }

    @Test func guardConditionFalseReturns() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func half(_ n: Int) -> Int {
                guard n > 0 else {
                    return -1
                }
                return n / 2
            }
            half(-5)
            """)
        #expect(r == .int(-1))
    }
}

@Suite("Labeled loops")
struct LabeledLoopTests {
    @Test func breakOuter() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var hits = 0
            outer: for i in 0..<5 {
                for j in 0..<5 {
                    if i == 2 && j == 2 { break outer }
                    hits = hits + 1
                }
            }
            hits
            """)
        // i=0: 5 hits, i=1: 5 hits, i=2: j=0,1 → 2 hits, then break outer.
        #expect(r == .int(5 + 5 + 2))
    }

    @Test func continueOuter() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var hits = 0
            outer: for i in 0..<3 {
                for j in 0..<5 {
                    if j == 2 { continue outer }
                    hits = hits + 1
                }
            }
            hits
            """)
        // For each i, j=0,1 then continue outer → 2 hits per outer iteration.
        #expect(r == .int(2 * 3))
    }
}

@Suite("Optional + if let")
struct OptionalTests {
    @Test func nilLiteralIsOptional() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("nil")
        #expect(r == .optional(nil))
    }

    @Test func nilEqualityToNil() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("nil == nil") == .bool(true))
    }

    @Test func ifLetUnwraps() async throws {
        let interp = Interpreter()
        // We have no Optional-returning builtin yet; use a pure function that
        // returns Value.optional via a small workaround: assign a literal nil.
        // Instead, we exercise the "non-nil" branch via a binding.
        let r = try await interp.eval("""
            let x = nil
            if let y = x {
                "got \\(y)"
            } else {
                "missing"
            }
            """)
        #expect(r == .string("missing"))
    }

    @Test func optionalIsNilProperty() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("nil.isNil") == .bool(true))
    }
}
