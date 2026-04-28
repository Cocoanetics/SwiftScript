import Testing
@testable import SwiftScriptInterpreter

@Suite("Array factories, zip, stride, statics")
struct StdLibTests {
    @Test func arrayFromRange() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("Array(0..<5)")
        #expect(r == .array([.int(0), .int(1), .int(2), .int(3), .int(4)]))
    }

    @Test func arrayFromString() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"Array("abc")"#)
        #expect(r == .array([.string("a"), .string("b"), .string("c")]))
    }

    @Test func typedArrayRepeating() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[Int](repeating: 0, count: 4)")
        #expect(r == .array([.int(0), .int(0), .int(0), .int(0)]))
    }

    @Test func typedArrayEmpty() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[Int]()")
        #expect(r == .array([]))
    }

    @Test func typedArrayEmptyThenAppend() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [Int]()
            a += [1, 2, 3]
            a
            """)
        #expect(r == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func zipTwoSequences() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"Array(zip(0..<3, ["a", "b", "c"]))"#)
        #expect(r == .array([
            .tuple([.int(0), .string("a")]),
            .tuple([.int(1), .string("b")]),
            .tuple([.int(2), .string("c")]),
        ]))
    }

    @Test func zipTruncates() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("Array(zip([1, 2, 3, 4], [10, 20]))")
        #expect(r == .array([
            .tuple([.int(1), .int(10)]),
            .tuple([.int(2), .int(20)]),
        ]))
    }

    @Test func strideIntBy2() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("Array(stride(from: 0, to: 10, by: 2))")
        #expect(r == .array([.int(0), .int(2), .int(4), .int(6), .int(8)]))
    }

    @Test func strideDouble() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("Array(stride(from: 0.0, to: 1.0, by: 0.25))")
        #expect(r == .array([.double(0.0), .double(0.25), .double(0.5), .double(0.75)]))
    }

    @Test func intMaxMin() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("Int.max") == .int(Int.max))
        #expect(try await interp.eval("Int.min") == .int(Int.min))
    }

    @Test func doubleStatics() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("Double.pi") == .double(.pi))
        #expect(try await interp.eval("Double.infinity") == .double(.infinity))
        #expect(try await interp.eval("Double.nan.isNaN") == .bool(true))
        #expect(try await interp.eval("Double.infinity.isInfinite") == .bool(true))
        #expect(try await interp.eval("(1.0).isFinite") == .bool(true))
    }

    @Test func intRandomInRange() async throws {
        let interp = Interpreter()
        // Property: result is always within the requested half-open range.
        for _ in 0..<20 {
            let r = try await interp.eval("Int.random(in: 10..<20)")
            guard case .int(let v) = r else { Issue.record("not int"); return }
            #expect(v >= 10 && v < 20)
        }
    }

    @Test func intRandomClosedRange() async throws {
        let interp = Interpreter()
        for _ in 0..<20 {
            let r = try await interp.eval("Int.random(in: 1...3)")
            guard case .int(let v) = r else { Issue.record("not int"); return }
            #expect(v >= 1 && v <= 3)
        }
    }
}
