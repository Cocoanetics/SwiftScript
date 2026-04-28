import Testing
@testable import SwiftScriptInterpreter

@Suite("throws / try / catch")
struct ThrowsTests {
    @Test func throwAndCatchDefault() async throws {
        let interp = Interpreter()
        var captured = ""
        let i = Interpreter(output: { captured += $0 + "\n" })
        try await i.eval("""
            enum E: Error { case bad }
            func f() async throws { throw E.bad }
            do { try f() } catch { print("caught:", error) }
            """)
        _ = interp
        #expect(captured == "caught: bad\n")
    }

    @Test func throwWithPayloadCaughtByPattern() async throws {
        let i = Interpreter()
        var captured = ""
        i.output = { captured += $0 + "\n" }
        try await i.eval("""
            enum E: Error { case parse(String) }
            func f() throws -> Int { throw E.parse("oops") }
            do {
                let _ = try f()
            } catch E.parse(let m) {
                print("err:", m)
            } catch {
                print("other")
            }
            """)
        #expect(captured == "err: oops\n")
    }

    @Test func tryQuestionReturnsNilOnThrow() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum E: Error { case bad }
            func f() throws -> Int { throw E.bad }
            let r = try? f()
            r ?? -1
            """)
        #expect(r == .int(-1))
    }

    @Test func tryQuestionReturnsValueOnSuccess() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func f() throws -> Int { return 42 }
            (try? f()) ?? -1
            """)
        #expect(r == .int(42))
    }

    @Test func tryBangPropagatesValueOnSuccess() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func f() throws -> Int { return 99 }
            try! f()
            """)
        #expect(r == .int(99))
    }

    @Test func tryBangThrowsOnFailure() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("""
                enum E: Error { case bad }
                func f() throws -> Int { throw E.bad }
                try! f()
                """)
        }
    }

    @Test func doWithoutThrow() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"do { print("hello") }"#)
        #expect(captured == "hello\n")
    }

    @Test func uncaughtErrorPropagates() async throws {
        let interp = Interpreter()
        await #expect(throws: UserThrowSignal.self) {
            _ = try await interp.eval("""
                enum E: Error { case bad }
                throw E.bad
                """)
        }
    }

    @Test func multipleCatchClausesPickFirstMatch() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum E: Error { case a, b, c }
            func describe() -> String {
                do {
                    throw E.b
                } catch E.a { return "a" }
                catch E.b   { return "b" }
                catch       { return "default" }
            }
            describe()
            """)
        #expect(r == .string("b"))
    }
}
