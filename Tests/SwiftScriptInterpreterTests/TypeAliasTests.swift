import Testing
@testable import SwiftScriptInterpreter

@Suite("Typealias")
struct TypeAliasTests {
    @Test func aliasForDouble() async throws {
        let interp = Interpreter()
        // Integer literal coerces through the alias to Double.
        let r = try await interp.eval("""
            typealias Number = Double
            let x: Number = 5
            x
            """)
        #expect(r == .double(5.0))
    }

    @Test func aliasForUserStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point { var x: Int; var y: Int }
            typealias P2 = Point
            P2(x: 3, y: 4)
            """)
        #expect(r.description == "Point(x: 3, y: 4)")
    }

    @Test func aliasForArray() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            typealias Ints = [Int]
            let xs: Ints = [1, 2, 3]
            xs
            """)
        #expect(r == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func aliasChain() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            typealias A = Int
            typealias B = A
            let n: B = 42
            n
            """)
        #expect(r == .int(42))
    }

    @Test func aliasForEnumWorksWithRawValueInit() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum D: String { case a = "A"; case b = "B" }
            typealias DAlias = D
            DAlias(rawValue: "A")
            """#)
        guard case .optional(.some(let v)) = r,
              case .enumValue(_, let c, _) = v else {
            Issue.record("expected Optional(.a), got \(r)"); return
        }
        #expect(c == "a")
    }
}
