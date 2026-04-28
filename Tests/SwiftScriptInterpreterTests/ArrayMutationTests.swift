import Testing
@testable import SwiftScriptInterpreter

@Suite("Array mutation")
struct ArrayMutationTests {
    @Test func appendOne() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var a = [1, 2, 3]; a.append(4); a")
        #expect(r == .array([.int(1), .int(2), .int(3), .int(4)]))
    }

    @Test func appendContentsOf() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("var a = [1, 2]; a.append(contentsOf: [3, 4]); a")
        #expect(r == .array([.int(1), .int(2), .int(3), .int(4)]))
    }

    @Test func removeLastReturnsValue() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [10, 20, 30]
            let last = a.removeLast()
            (last, a)
            """)
        #expect(r == .tuple([.int(30), .array([.int(10), .int(20)])]))
    }

    @Test func removeFirstReturnsValue() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [10, 20, 30]
            let first = a.removeFirst()
            (first, a)
            """)
        #expect(r == .tuple([.int(10), .array([.int(20), .int(30)])]))
    }

    @Test func insertAtIndex() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [1, 2, 3]
            a.insert(99, at: 1)
            a
            """)
        #expect(r == .array([.int(1), .int(99), .int(2), .int(3)]))
    }

    @Test func removeAtIndex() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [10, 20, 30]
            let removed = a.remove(at: 1)
            (removed, a)
            """)
        #expect(r == .tuple([.int(20), .array([.int(10), .int(30)])]))
    }

    @Test func appendOnLetThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("let a = [1, 2]; a.append(3)")
        }
    }

    @Test func subscriptSet() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var a = [10, 20, 30]
            a[1] = 99
            a
            """)
        #expect(r == .array([.int(10), .int(99), .int(30)]))
    }

    @Test func iterativeBuildup() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            var primes: [Int] = []
            for n in 2...20 {
                var isPrime = n >= 2
                if n > 2 {
                    var i = 2
                    while i * i <= n {
                        if n % i == 0 { isPrime = false; break }
                        i += 1
                    }
                }
                if isPrime { primes.append(n) }
            }
            primes
            """)
        #expect(r == .array([
            .int(2), .int(3), .int(5), .int(7),
            .int(11), .int(13), .int(17), .int(19),
        ]))
    }
}
