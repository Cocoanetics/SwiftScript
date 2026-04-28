import Testing
@testable import SwiftScriptInterpreter

@Suite("Extensions")
struct ExtensionTests {
    @Test func methodOnUserStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V { var x: Double; var y: Double }
            extension V {
                func length() -> Double { (x*x + y*y).squareRoot() }
            }
            V(x: 3, y: 4).length()
            """)
        #expect(r == .double(5.0))
    }

    @Test func computedPropertyOnUserStruct() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V { var x: Double; var y: Double }
            extension V { var length: Double { (x*x + y*y).squareRoot() } }
            V(x: 3, y: 4).length
            """)
        #expect(r == .double(5.0))
    }

    @Test func methodOnInt() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            extension Int { func squared() -> Int { self * self } }
            7.squared()
            """)
        #expect(r == .int(49))
    }

    @Test func computedPropertyOnInt() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            extension Int { var doubled: Int { self * 2 } }
            5.doubled
            """)
        #expect(r == .int(10))
    }

    @Test func staticFuncViaExtension() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct V { var x: Int }
            extension V { static func zero() -> V { V(x: 0) } }
            V.zero()
            """)
        guard case .structValue = r else { Issue.record("not struct"); return }
        #expect(r.description == "V(x: 0)")
    }

    @Test func computedPropertyOnEnum() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum Color { case red, green }
            extension Color {
                var name: String {
                    switch self {
                    case .red:   return "R"
                    case .green: return "G"
                    }
                }
            }
            (Color.red.name, Color.green.name)
            """#)
        #expect(r == .tuple([.string("R"), .string("G")]))
    }

    @Test func extensionWithMultipleMembers() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            extension Int {
                func cubed() -> Int { self * self * self }
                var isEven: Bool { self % 2 == 0 }
            }
            (3.cubed(), 4.isEven, 5.isEven)
            """)
        #expect(r == .tuple([.int(27), .bool(true), .bool(false)]))
    }
}
