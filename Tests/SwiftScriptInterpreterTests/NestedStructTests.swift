import Testing
@testable import SwiftScriptInterpreter

@Suite("Nested structs")
struct NestedStructTests {
    @Test func structFieldOfStructType() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point { var x: Int; var y: Int }
            struct Line { var start: Point; var end: Point }
            let l = Line(start: Point(x: 1, y: 2), end: Point(x: 3, y: 4))
            l.end.x
            """)
        #expect(r == .int(3))
    }

    @Test func nestedPropertyAssignment() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point { var x: Int; var y: Int }
            struct Line { var start: Point; var end: Point }
            var l = Line(start: Point(x: 0, y: 0), end: Point(x: 0, y: 0))
            l.start.x = 5
            l.end.y = 7
            (l.start.x, l.end.y)
            """)
        #expect(r == .tuple([.int(5), .int(7)]))
    }

    @Test func nestedCompoundAssignment() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P { var x: Int; var y: Int }
            struct Box { var p: P }
            var b = Box(p: P(x: 0, y: 0))
            b.p.x += 10
            b.p.y += 20
            b.p
            """)
        #expect(r == .structValue(typeName: "P", fields: [
            StructField(name: "x", value: .int(10)),
            StructField(name: "y", value: .int(20)),
        ]))
    }

    @Test func mutatingMethodOnNestedStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C { var n: Int; mutating func bump() async throws { n += 1 } }
            struct Outer { var c: C }
            var o = Outer(c: C(n: 5))
            o.c.bump()
            o.c.bump()
            o.c.n
            """)
        #expect(r == .int(7))
    }

    @Test func deepNestingThreeLevels() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct A { var n: Int }
            struct B { var a: A }
            struct C { var b: B }
            var c = C(b: B(a: A(n: 1)))
            c.b.a.n = 99
            c.b.a.n
            """)
        #expect(r == .int(99))
    }

    @Test func nestedAssignmentOnLetThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct P { var x: Int }
                struct B { var p: P }
                let b = B(p: P(x: 1))
                b.p.x = 5
                """)
        }
    }
}
