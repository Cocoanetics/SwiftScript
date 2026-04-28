import Testing
@testable import SwiftScriptInterpreter

@Suite("Structs")
struct StructTests {
    @Test func memberwiseInitAndPrint() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point { var x: Double; var y: Double }
            let p = Point(x: 3, y: 4)
            p
            """)
        #expect(r.description == "Point(x: 3.0, y: 4.0)")
    }

    @Test func propertyAccess() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point { var x: Double; var y: Double }
            let p = Point(x: 3, y: 4)
            p.x + p.y
            """)
        #expect(r == .double(7.0))
    }

    @Test func methodWithImplicitSelf() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point {
                var x: Double
                var y: Double
                func length() -> Double { (x*x + y*y).squareRoot() }
            }
            Point(x: 3, y: 4).length()
            """)
        #expect(r == .double(5.0))
    }

    @Test func methodTakingOtherInstance() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Point {
                var x: Double
                var y: Double
                func distance(to other: Point) -> Double {
                    let dx = x - other.x
                    let dy = y - other.y
                    return (dx*dx + dy*dy).squareRoot()
                }
            }
            Point(x: 0, y: 0).distance(to: Point(x: 3, y: 4))
            """)
        #expect(r == .double(5.0))
    }

    @Test func methodReturnsStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V { var x: Double; var y: Double
                func add(_ o: V) -> V { V(x: x + o.x, y: y + o.y) }
            }
            V(x: 1, y: 2).add(V(x: 10, y: 20))
            """)
        #expect(r.description == "V(x: 11.0, y: 22.0)")
    }

    @Test func equality() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P { var x: Int; var y: Int }
            let a = P(x: 1, y: 2)
            let b = P(x: 1, y: 2)
            let c = P(x: 9, y: 9)
            (a == b, a == c)
            """)
        #expect(r == .tuple([.bool(true), .bool(false)]))
    }

    @Test func valueSemanticsLikeAssignment() async throws {
        let interp = Interpreter()
        // Assigning a struct copies. Mutating the copy doesn't affect the
        // original. (Without mutating methods, we use property assignment
        // on the var copy.)
        let r = try await interp.eval("""
            struct P { var x: Int }
            var a = P(x: 1)
            var b = a
            b.x = 99
            (a.x, b.x)
            """)
        #expect(r == .tuple([.int(1), .int(99)]))
    }

    @Test func propertyAssignmentOnVarStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P { var x: Int }
            var p = P(x: 1)
            p.x = 5
            p.x
            """)
        #expect(r == .int(5))
    }

    @Test func propertyAssignmentOnLetThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct P { var x: Int }
                let p = P(x: 1)
                p.x = 5
                """)
        }
    }

    @Test func missingArgInInitThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct P { var x: Int; var y: Int }
                let _ = P(x: 1)
                """)
        }
    }

    @Test func wrongTypeArgThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval(#"""
                struct P { var x: Int }
                let _ = P(x: "hi")
                """#)
        }
    }

    @Test func integerLiteralCoercesToDoubleProperty() async throws {
        // Same literal-polymorphism as let/func params.
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct P { var x: Double }
            P(x: 5).x
            """)
        #expect(r == .double(5.0))
    }
}
