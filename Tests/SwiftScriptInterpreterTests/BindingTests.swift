import Testing
@testable import SwiftScriptInterpreter

@Suite("Bindings & functions")
struct BindingTests {
    @Test func letBindingPersistsAcrossEvals() async throws {
        let interp = Interpreter()
        try await interp.eval("let x = 42")
        #expect(try await interp.eval("x + 1") == .int(43))
    }

    @Test func varReassignment() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var x = 10
            x = x + 5
            x
            """)
        #expect(r == .int(15))
    }

    @Test func letIsImmutable() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                let y = 1
                y = 2
                """)
        }
    }

    @Test func userFunction() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func square(_ n: Int) -> Int {
                return n * n
            }
            square(7)
            """)
        #expect(r == .int(49))
    }

    @Test func functionCapturesEnclosingScope() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let factor = 3
            func scale(_ n: Int) -> Int {
                return n * factor
            }
            scale(5)
            """)
        #expect(r == .int(15))
    }

    @Test func stringInterpolation() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let name = "world"
            "hello, \(name)!"
            """#)
        #expect(r == .string("hello, world!"))
    }
}
