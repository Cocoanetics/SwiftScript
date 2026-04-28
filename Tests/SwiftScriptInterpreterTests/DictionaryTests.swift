import Testing
@testable import SwiftScriptInterpreter

@Suite("Dictionaries")
struct DictionaryTests {
    @Test func literalAndLookup() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let d = ["a": 1, "b": 2]
            (d["a"]!, d["c"] ?? -1)
            """#)
        #expect(r == .tuple([.int(1), .int(-1)]))
    }

    @Test func emptyDictTypedInit() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var d = [String: Int]()
            d["x"] = 5
            d["x"]!
            """)
        #expect(r == .int(5))
    }

    @Test func emptyDictColonLiteral() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[String: Int]()")
        #expect(r == .dict([]))
    }

    @Test func count() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#"["a": 1, "b": 2].count"#) == .int(2))
        #expect(try await interp.eval(#"["a": 1].isEmpty"#) == .bool(false))
        #expect(try await interp.eval("[String: Int]().isEmpty") == .bool(true))
    }

    @Test func setOverwrites() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            var d = ["a": 1]
            d["a"] = 99
            d["a"]!
            """#)
        #expect(r == .int(99))
    }

    @Test func setNilRemoves() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            var d = ["a": 1, "b": 2]
            d["a"] = nil
            (d.count, d["a"] == nil)
            """#)
        #expect(r == .tuple([.int(1), .bool(true)]))
    }

    @Test func iteration() async throws {
        let interp = Interpreter()
        var lines: [String] = []
        interp.output = { lines.append($0) }
        try await interp.eval(#"""
            let d = ["a": 1, "b": 2, "c": 3]
            var sum = 0
            for (_, v) in d { sum += v }
            print(sum)
            """#)
        #expect(lines == ["6"])
    }

    @Test func keysAndValues() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let d = ["a": 1, "b": 2]
            (d.keys.sorted(), d.values.sorted())
            """#)
        #expect(r == .tuple([
            .array([.string("a"), .string("b")]),
            .array([.int(1), .int(2)]),
        ]))
    }

    @Test func arraySubscriptSet() async throws {
        // Bonus: subscript-set machinery handles arrays too.
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [10, 20, 30]
            a[1] = 99
            a
            """)
        #expect(r == .array([.int(10), .int(99), .int(30)]))
    }
}
