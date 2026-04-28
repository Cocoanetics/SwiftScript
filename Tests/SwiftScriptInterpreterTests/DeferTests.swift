import Testing
@testable import SwiftScriptInterpreter

@Suite("defer")
struct DeferTests {
    @Test func runsAtFunctionExit() async throws {
        let interp = Interpreter()
        var lines: [String] = []
        interp.output = { lines.append($0) }
        try await interp.eval("""
            func f() async throws {
                defer { print("d1") }
                print("body")
            }
            f()
            """)
        #expect(lines == ["body", "d1"])
    }

    @Test func multipleRunInReverseOrder() async throws {
        let interp = Interpreter()
        var lines: [String] = []
        interp.output = { lines.append($0) }
        try await interp.eval("""
            func f() async throws {
                defer { print("d1") }
                defer { print("d2") }
                print("body")
            }
            f()
            """)
        #expect(lines == ["body", "d2", "d1"])
    }

    @Test func runsBeforeReturnValueIsConsumed() async throws {
        let interp = Interpreter()
        var lines: [String] = []
        interp.output = { lines.append($0) }
        try await interp.eval("""
            func f() -> Int {
                defer { print("cleanup") }
                return 42
            }
            print(f())
            """)
        #expect(lines == ["cleanup", "42"])
    }

    @Test func runsOnThrow() async throws {
        let interp = Interpreter()
        var lines: [String] = []
        interp.output = { lines.append($0) }
        try await interp.eval("""
            enum E: Error { case bad }
            func f() async throws {
                defer { print("d") }
                throw E.bad
            }
            do { try f() } catch { print("caught") }
            """)
        #expect(lines == ["d", "caught"])
    }

    @Test func deferInsideBlockScope() async throws {
        // defer fires at the end of its enclosing scope, not the function.
        let interp = Interpreter()
        var lines: [String] = []
        interp.output = { lines.append($0) }
        try await interp.eval("""
            func f() async throws {
                if true {
                    defer { print("inner-d") }
                    print("inside if")
                }
                print("outside if")
            }
            f()
            """)
        #expect(lines == ["inside if", "inner-d", "outside if"])
    }
}
