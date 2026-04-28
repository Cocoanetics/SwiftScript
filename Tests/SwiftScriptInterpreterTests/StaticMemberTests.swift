import Testing
@testable import SwiftScriptInterpreter

@Suite("Static struct members")
struct StaticMemberTests {
    @Test func staticLet() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct M { static let pi = 3.14 }
            M.pi
            """)
        #expect(r == .double(3.14))
    }

    @Test func staticFunc() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct M { static func square(_ n: Int) -> Int { n * n } }
            M.square(7)
            """)
        #expect(r == .int(49))
    }

    @Test func staticVarComputedAtDeclTime() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            struct M { static var version: String { "1.0" } }
            M.version
            """#)
        #expect(r == .string("1.0"))
    }

    @Test func staticReferencedFromInstanceMethod() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C {
                static let limit = 100
                var n: Int
                func clamp() -> Int { n > C.limit ? C.limit : n }
            }
            C(n: 200).clamp()
            """)
        #expect(r == .int(100))
    }

    @Test func staticFactoryReferencingOwnType() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V {
                var x: Int
                var y: Int
                static let zero = V(x: 0, y: 0)
            }
            V.zero
            """)
        #expect(r == .structValue(typeName: "V", fields: [
            StructField(name: "x", value: .int(0)),
            StructField(name: "y", value: .int(0)),
        ]))
    }
}
