import Testing
@testable import SwiftScriptInterpreter

@Suite("Conformances + custom operators")
struct ConformanceTests {
    @Test func equatableMemberwise() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P: Equatable { var x: Int; var y: Int }
            P(x: 1, y: 2) == P(x: 1, y: 2)
            """)
        #expect(r == .bool(true))
    }

    @Test func arrayContainsUsesMemberwiseEquality() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P: Equatable { var x: Int }
            [P(x: 1), P(x: 2)].contains(P(x: 1))
            """)
        #expect(r == .bool(true))
    }

    @Test func customLessOperatorEnablesSort() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P: Comparable {
                var x: Int
                static func < (a: P, b: P) -> Bool { a.x < b.x }
            }
            [P(x: 3), P(x: 1), P(x: 2)].sorted().map { $0.x }
            """)
        #expect(r == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func customEqualOperatorOverride() async throws {
        // User-defined `==` overrides memberwise structural equality.
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P {
                var x: Int
                static func == (a: P, b: P) -> Bool { a.x % 2 == b.x % 2 }
            }
            P(x: 3) == P(x: 5)
            """)
        #expect(r == .bool(true))
    }

    @Test func customPlusOperator() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V {
                var x: Int
                var y: Int
                static func + (a: V, b: V) -> V {
                    V(x: a.x + b.x, y: a.y + b.y)
                }
            }
            V(x: 1, y: 2) + V(x: 3, y: 4)
            """)
        #expect(r == .structValue(typeName: "V", fields: [
            StructField(name: "x", value: .int(4)),
            StructField(name: "y", value: .int(6)),
        ]))
    }
}
