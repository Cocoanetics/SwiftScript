import Testing
@testable import SwiftScriptInterpreter

@Suite("Computed properties")
struct ComputedPropertyTests {
    @Test func shorthandBody() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct R { var w: Double; var h: Double; var area: Double { w * h } }
            R(w: 3, h: 4).area
            """)
        #expect(r == .double(12.0))
    }

    @Test func explicitGet() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct R {
                var w: Double
                var h: Double
                var area: Double { get { w * h } }
            }
            R(w: 5, h: 2).area
            """)
        #expect(r == .double(10.0))
    }

    @Test func computedUsingSelf() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V {
                var x: Double
                var y: Double
                var length: Double { (x*x + y*y).squareRoot() }
            }
            V(x: 3, y: 4).length
            """)
        #expect(r == .double(5.0))
    }

    @Test func computedReturningStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V {
                var x: Double
                var y: Double
                var doubled: V { V(x: x*2, y: y*2) }
            }
            V(x: 1, y: 2).doubled
            """)
        #expect(r == .structValue(typeName: "V", fields: [
            StructField(name: "x", value: .double(2.0)),
            StructField(name: "y", value: .double(4.0)),
        ]))
    }

    @Test func computedNotInMemberwiseInit() async throws {
        // Computed properties must NOT appear as init arguments.
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct R { var w: Double; var area: Double { w * 2 } }
                let _ = R(w: 1, area: 2)
                """)
        }
    }

    @Test func computedAlongsideMethods() async throws {
        let interp = Interpreter()
        // A struct with both a computed property and a method, exercised
        // together. A circle with `area` (computed) and `scaled(by:)`
        // returning a new circle.
        let r = try await interp.eval("""
            struct Circle {
                var r: Double
                var area: Double { Double.pi * r * r }
                func scaled(by k: Double) -> Circle { Circle(r: r * k) }
            }
            Circle(r: 2).scaled(by: 3).area
            """)
        guard case .double(let v) = r else { Issue.record("not double"); return }
        // π · 36
        #expect(abs(v - .pi * 36) < 1e-12)
    }
}
