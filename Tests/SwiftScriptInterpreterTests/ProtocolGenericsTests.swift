import Testing
@testable import SwiftScriptInterpreter

@Suite("Protocols + generics")
struct ProtocolGenericsTests {
    @Test func protocolDeclIsAccepted() async throws {
        // We don't enforce conformance — duck-typed dispatch handles it.
        // Just verify the syntax parses and runs.
        let interp = Interpreter()
        let r = try await interp.eval("""
            protocol Named { var name: String { get } }
            struct P: Named { var name: String }
            P(name: "Alice").name
            """)
        #expect(r == .string("Alice"))
    }

    @Test func protocolMethodDispatch() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            protocol Greeter { func greet() -> String }
            struct E: Greeter {
                var name: String
                func greet() -> String { "hi \(name)" }
            }
            E(name: "A").greet()
            """#)
        #expect(r == .string("hi A"))
    }

    @Test func genericFunctionWithoutEnforcement() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func swapEm<T>(_ a: T, _ b: T) -> (T, T) { (b, a) }
            swapEm(1, 2)
            """)
        #expect(r == .tuple([.int(2), .int(1)]))
    }

    @Test func genericFunctionWithStringInstance() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func swapEm<T>(_ a: T, _ b: T) -> (T, T) { (b, a) }
            swapEm("a", "b")
            """#)
        #expect(r == .tuple([.string("b"), .string("a")]))
    }

    @Test func genericComparableFunction() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func maxOf<T: Comparable>(_ a: T, _ b: T) -> T { a > b ? a : b }
            (maxOf(3, 7), maxOf("a", "b"))
            """#)
        #expect(r == .tuple([.int(7), .string("b")]))
    }

    @Test func genericStructStackWithDefault() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Stack<T> {
                var items: [T] = []
                mutating func push(_ x: T) { items.append(x) }
                mutating func pop() -> T { items.removeLast() }
            }
            var s = Stack<Int>()
            s.push(1)
            s.push(2)
            s.push(3)
            (s.pop(), s.pop(), s.pop())
            """)
        #expect(r == .tuple([.int(3), .int(2), .int(1)]))
    }

    @Test func genericStructInferred() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Box<T> { var value: T }
            let b = Box(value: 42)
            b.value
            """)
        #expect(r == .int(42))
    }

    @Test func propertyDefaultUsedWhenOmitted() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            struct Settings {
                var debug: Bool = false
                var name: String = "default"
            }
            let s = Settings()
            (s.debug, s.name)
            """)
        #expect(r == .tuple([.bool(false), .string("default")]))
    }
}
