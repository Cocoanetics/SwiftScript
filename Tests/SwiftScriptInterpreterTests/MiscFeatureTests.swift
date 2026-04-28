import Testing
@testable import SwiftScriptInterpreter

@Suite("String(format:) + import + operator-as-function")
struct MiscFeatureTests {
    @Test func stringFormatTwoDecimals() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            String(format: "%.2f", 3.14159)
            """#)
        #expect(r == .string("3.14"))
    }

    @Test func stringFormatMultipleArgs() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            String(format: "%d + %d = %d", 2, 3, 5)
            """#)
        #expect(r == .string("2 + 3 = 5"))
    }

    @Test func stringFormatInteger0Pad() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            String(format: "%03d", 7)
            """#)
        #expect(r == .string("007"))
    }

    @Test func importFoundationIsNoOp() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            import Foundation
            String(format: "%.1f", 1.5)
            """)
        #expect(r == .string("1.5"))
    }

    @Test func reducePlus() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2, 3, 4].reduce(0, +)") == .int(10))
    }

    @Test func reduceTimes() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2, 3, 4].reduce(1, *)") == .int(24))
    }

    @Test func sortedByGreaterThan() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[3, 1, 4, 1, 5].sorted(by: >)")
        #expect(r == .array([.int(5), .int(4), .int(3), .int(1), .int(1)]))
    }
}
