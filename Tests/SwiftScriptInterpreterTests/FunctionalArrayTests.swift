import Testing
@testable import SwiftScriptInterpreter

@Suite("Functional Array methods")
struct FunctionalArrayTests {
    @Test func mapDoubles() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3].map { $0 * 2 }")
        #expect(r == .array([.int(2), .int(4), .int(6)]))
    }

    @Test func mapEmpty() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let xs: [Int] = []
            xs.map { $0 * 2 }
            """)
        #expect(r == .array([]))
    }

    @Test func filter() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3, 4, 5].filter { $0 % 2 == 0 }")
        #expect(r == .array([.int(2), .int(4)]))
    }

    @Test func reduceSum() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3, 4].reduce(0) { $0 + $1 }")
        #expect(r == .int(10))
    }

    @Test func reduceProduct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3, 4].reduce(1) { $0 * $1 }")
        #expect(r == .int(24))
    }

    @Test func compactMapParseInts() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"["1", "x", "3"].compactMap { Int($0) }"#)
        #expect(r == .array([.int(1), .int(3)]))
    }

    @Test func forEachSideEffect() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var s = 0
            [1, 2, 3].forEach { s += $0 }
            s
            """)
        #expect(r == .int(6))
    }

    @Test func chainedPipeline() async throws {
        // sum of squares of [1..6] keeping those < 20: 1 + 4 + 9 + 16 = 30
        let interp = Interpreter()
        let r = try await interp.eval("""
            [1, 2, 3, 4, 5, 6]
                .map { $0 * $0 }
                .filter { $0 < 20 }
                .reduce(0) { $0 + $1 }
            """)
        #expect(r == .int(30))
    }

    @Test func mapIntToDouble() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3].map { Double($0) * 1.5 }")
        #expect(r == .array([.double(1.5), .double(3.0), .double(4.5)]))
    }

    @Test func mapWithCapturedVar() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let factor = 10
            [1, 2, 3].map { $0 * factor }
            """)
        #expect(r == .array([.int(10), .int(20), .int(30)]))
    }
}
