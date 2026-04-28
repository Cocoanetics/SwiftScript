import Testing
@testable import SwiftScriptInterpreter

@Suite("Arrays")
struct ArrayTests {
    @Test func arrayLiteral() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3]")
        #expect(r == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func emptyArrayLiteral() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[]")
        #expect(r == .array([]))
    }

    @Test func mixedNumericArray() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2.5, 3]")
        #expect(r == .array([.int(1), .double(2.5), .int(3)]))
    }

    @Test func subscriptByIndex() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[10, 20, 30][1]")
        #expect(r == .int(20))
    }

    @Test func subscriptOutOfBoundsThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("[1, 2, 3][5]")
        }
    }

    @Test func count() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2, 3].count") == .int(3))
        #expect(try await interp.eval("[].count")        == .int(0))
    }

    @Test func isEmpty() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[].isEmpty")    == .bool(true))
        #expect(try await interp.eval("[1].isEmpty")   == .bool(false))
    }

    @Test func contains() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2, 3].contains(2)") == .bool(true))
        #expect(try await interp.eval("[1, 2, 3].contains(9)") == .bool(false))
    }

    @Test func concatenation() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("[1, 2] + [3, 4]") == .array([.int(1), .int(2), .int(3), .int(4)]))
    }

    @Test func joined() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"["foo", "bar", "baz"].joined(separator: "-")"#)
        #expect(r == .string("foo-bar-baz"))
    }

    @Test func iterateArray() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var sum = 0
            for n in [10, 20, 30] {
                sum = sum + n
            }
            sum
            """)
        #expect(r == .int(60))
    }

    @Test func forInWhere() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var sum = 0
            for n in [1, 2, 3, 4, 5] where n % 2 == 0 {
                sum = sum + n
            }
            sum
            """)
        #expect(r == .int(2 + 4))
    }
}

@Suite("Strings")
struct StringMethodTests {
    @Test func count() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#""hello".count"#) == .int(5))
    }

    @Test func hasPrefixSuffix() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#""filename.txt".hasSuffix(".txt")"#) == .bool(true))
        #expect(try await interp.eval(#""filename.txt".hasPrefix("file")"#) == .bool(true))
        #expect(try await interp.eval(#""filename.txt".hasSuffix(".md")"#)  == .bool(false))
    }

    @Test func caseTransforms() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(#""Hello".uppercased()"#) == .string("HELLO"))
        #expect(try await interp.eval(#""Hello".lowercased()"#) == .string("hello"))
    }

    @Test func iterateCharacters() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            var out = ""
            for c in "abc" {
                out = out + c.uppercased()
            }
            out
            """#)
        #expect(r == .string("ABC"))
    }
}
