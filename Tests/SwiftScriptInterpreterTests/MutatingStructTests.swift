import Testing
@testable import SwiftScriptInterpreter

@Suite("Mutating struct methods")
struct MutatingStructTests {
    @Test func mutatingFuncBumpsProperty() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Counter {
                var n: Int
                mutating func bump() async throws { n += 1 }
            }
            var c = Counter(n: 1)
            c.bump()
            c.bump()
            c.n
            """)
        #expect(r == .int(3))
    }

    @Test func mutatingFuncWithArgs() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V {
                var x: Int
                var y: Int
                mutating func translate(by dx: Int, _ dy: Int) {
                    x += dx
                    y += dy
                }
            }
            var v = V(x: 0, y: 0)
            v.translate(by: 3, 4)
            v
            """)
        #expect(r == .structValue(typeName: "V", fields: [
            StructField(name: "x", value: .int(3)),
            StructField(name: "y", value: .int(4)),
        ]))
    }

    @Test func mutatingReassignsSelfWhole() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C {
                var n: Int
                mutating func reset() async throws { self = C(n: 0) }
            }
            var c = C(n: 99)
            c.reset()
            c.n
            """)
        #expect(r == .int(0))
    }

    @Test func mutatingExplicitSelfAssignment() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C {
                var n: Int
                mutating func bump() async throws { self.n += 1 }
            }
            var c = C(n: 5)
            c.bump()
            c.n
            """)
        #expect(r == .int(6))
    }

    @Test func mutatingOnLetThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct C { var n: Int; mutating func bump() async throws { n += 1 } }
                let c = C(n: 1)
                c.bump()
                """)
        }
    }

    @Test func nonMutatingCannotWriteSelfThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct C { var n: Int; func bump() async throws { n += 1 } }
                var c = C(n: 1)
                c.bump()
                """)
        }
    }

    @Test func mutatingMethodChainedFromOtherMethod() async throws {
        // A non-mutating method can call a mutating method only on a local
        // copy — Swift would reject that with "cannot pass immutable value
        // of type 'C' as inout argument" if it were on self. Verify a
        // simple chain on a local var works.
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C {
                var n: Int
                mutating func add(_ k: Int) { n += k }
            }
            var c = C(n: 0)
            c.add(3)
            c.add(7)
            c.n
            """)
        #expect(r == .int(10))
    }

    @Test func valueSemanticsAfterMutation() async throws {
        // Mutating one var doesn't affect a copy taken before.
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C { var n: Int; mutating func bump() async throws { n += 1 } }
            var a = C(n: 0)
            var b = a
            a.bump()
            a.bump()
            (a.n, b.n)
            """)
        #expect(r == .tuple([.int(2), .int(0)]))
    }
}
