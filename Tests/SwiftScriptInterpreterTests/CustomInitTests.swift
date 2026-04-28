import Testing
@testable import SwiftScriptInterpreter

@Suite("Custom init bodies")
struct CustomInitTests {
    @Test func customInitTransformsArg() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct C {
                var x: Int
                init(x: Int) { self.x = x * 2 }
            }
            C(x: 5).x
            """)
        #expect(r == .int(10))
    }

    @Test func customInitWithValidationFallback() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            struct C {
                var x: Int
                init(_ raw: String) { self.x = Int(raw) ?? 0 }
            }
            (C("42").x, C("nope").x)
            """#)
        #expect(r == .tuple([.int(42), .int(0)]))
    }

    @Test func customInitDerivedProperty() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct R {
                var w: Double
                var h: Double
                var area: Double
                init(w: Double, h: Double) {
                    self.w = w
                    self.h = h
                    self.area = w * h
                }
            }
            R(w: 3, h: 4).area
            """)
        #expect(r == .double(12.0))
    }

    @Test func customInitSuppressesMemberwise() async throws {
        // A custom init removes the auto-generated memberwise init.
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                struct C { var x: Int; init(_ k: Int) { self.x = k * k } }
                let _ = C(x: 5)
                """)
        }
    }

    @Test func multipleCustomInitsByLabels() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            struct C {
                var x: Int
                init(x: Int) { self.x = x }
                init(double y: Int) { self.x = y * 2 }
            }
            (C(x: 7).x, C(double: 7).x)
            """#)
        #expect(r == .tuple([.int(7), .int(14)]))
    }
}
