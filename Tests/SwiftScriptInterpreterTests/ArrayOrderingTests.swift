import Testing
@testable import SwiftScriptInterpreter

@Suite("Array ordering & aggregation")
struct ArrayOrderingTests {
    @Test func sortedAscending() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[3, 1, 4, 1, 5, 9, 2, 6].sorted()")
        #expect(r == .array([.int(1), .int(1), .int(2), .int(3), .int(4), .int(5), .int(6), .int(9)]))
    }

    @Test func sortedByClosureDescending() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[3, 1, 4, 1, 5, 9, 2, 6].sorted { $0 > $1 }")
        #expect(r == .array([.int(9), .int(6), .int(5), .int(4), .int(3), .int(2), .int(1), .int(1)]))
    }

    @Test func sortedStrings() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"["banana", "apple", "cherry"].sorted()"#)
        #expect(r == .array([.string("apple"), .string("banana"), .string("cherry")]))
    }

    @Test func reversedReturnsArray() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3, 4].reversed().map { $0 }")
        #expect(r == .array([.int(4), .int(3), .int(2), .int(1)]))
    }

    @Test func enumeratedYieldsTuples() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"["a", "b"].enumerated().map { $0 }"#)
        #expect(r == .array([
            .tuple([.int(0), .string("a")]),
            .tuple([.int(1), .string("b")]),
        ]))
    }

    @Test func forInTuplePatternFromEnumerated() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            var out = ""
            for (i, v) in ["a", "b", "c"].enumerated() {
                out += "\(i):\(v) "
            }
            out
            """#)
        #expect(r == .string("0:a 1:b 2:c "))
    }

    @Test func minOfInts() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[3, 1, 4].min()") == .optional(.int(1)))
    }

    @Test func maxOfInts() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[3, 1, 4].max()") == .optional(.int(4)))
    }

    @Test func minEmptyArrayReturnsNil() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let xs: [Int] = []
            xs.min()
            """)
        #expect(r == .optional(nil))
    }

    @Test func containsWhereTrue() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2, 3].contains(where: { $0 > 2 })") == .bool(true))
    }

    @Test func containsWhereFalse() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2, 3].contains(where: { $0 > 99 })") == .bool(false))
    }

    @Test func stringArrayPrintsWithQuotes() async throws {
        // Matches Swift's default print: `print(["a"])` → `["a"]`.
        let interp = Interpreter()
        let r = try await interp.eval(#"["apple", "pear"]"#)
        #expect(r.description == #"["apple", "pear"]"#)
    }
}
