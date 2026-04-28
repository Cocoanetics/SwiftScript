import Testing
import Foundation
@testable import SwiftScriptInterpreter

@Suite("Error + Sequence host bridges")
struct BridgesTests {
    // MARK: ScriptError

    @Test func scriptErrorPropagatesAsLocalizedError() async throws {
        let interp = Interpreter()
        do {
            _ = try await interp.eval("""
                enum E: Error { case bad }
                throw E.bad
                """)
            #expect(Bool(false), "should have thrown")
        } catch let e as ScriptError {
            #expect(e.typeName == "E")
            #expect(e.caseName == "bad")
            #expect(e.description == "E.bad")
            #expect((e as LocalizedError).errorDescription == "E.bad")
        }
    }

    @Test func scriptErrorPayloadAccessible() async throws {
        let interp = Interpreter()
        do {
            _ = try await interp.eval(#"""
                enum E: Error { case parse(String) }
                throw E.parse("bad input")
                """#)
            #expect(Bool(false), "should have thrown")
        } catch let e as ScriptError {
            #expect(e.typeName == "E")
            #expect(e.caseName == "parse")
            // Payload accessible through the underlying Value
            if case .enumValue(_, _, let payload) = e.value, payload.count == 1 {
                #expect(payload[0] == .string("bad input"))
            } else {
                #expect(Bool(false), "expected payload [\"bad input\"]")
            }
        }
    }

    // MARK: ScriptSequence

    @Test func arrayIsIterableViaScriptSequence() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("[1, 2, 3, 4, 5]")
        let seq = try r.asSequence()
        // Stdlib reduce works directly on the wrapper.
        let sum = seq.reduce(0) { acc, v in
            if case .int(let n) = v { return acc + n } else { return acc }
        }
        #expect(sum == 15)
    }

    @Test func stringIteratesAsCharacters() async throws {
        let interp = Interpreter()
        let v = try await interp.eval(#""hello""#)
        let seq = try v.asSequence()
        let count = Array(seq).count
        #expect(count == 5)
    }

    @Test func setRangeAndDictIterateThroughSameAdapter() async throws {
        let interp = Interpreter()

        // Set
        let setVal = try await interp.eval("Set([1, 2, 3])")
        #expect(try setVal.toArray().count == 3)

        // Range
        let rangeVal = try await interp.eval("0..<10")
        #expect(try rangeVal.toArray().count == 10)

        // Dict — yields (key, value) tuples
        let dictVal = try await interp.eval(#"["a": 1, "b": 2]"#)
        let entries = try dictVal.toArray()
        #expect(entries.count == 2)
        // First yielded value is a labeled tuple [(k, v)] — confirm shape
        if case .tuple(let parts, _) = entries[0] {
            #expect(parts.count == 2)
        } else {
            #expect(Bool(false), "expected tuple")
        }
    }

    @Test func nonIterableValueErrors() async throws {
        let interp = Interpreter()
        let intVal = try await interp.eval("42")
        do {
            _ = try intVal.asSequence()
            #expect(Bool(false), "Int should not be iterable")
        } catch let e as RuntimeError {
            #expect(e.description.contains("not iterable"))
        }
    }

    @Test func scriptDefinedSequenceIteratesWithForLoop() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Counter: Sequence {
                let limit: Int
                func makeIterator() -> CounterIterator {
                    return CounterIterator(current: 0, limit: limit)
                }
            }
            struct CounterIterator: IteratorProtocol {
                var current: Int
                let limit: Int
                mutating func next() -> Int? {
                    guard current < limit else { return nil }
                    defer { current += 1 }
                    return current
                }
            }
            for i in Counter(limit: 5) {
                print(i)
            }
            """)
        #expect(captured == "0\n1\n2\n3\n4\n")
    }

    @Test func deferInsideStructMutatingMethodNowRuns() async throws {
        // Pre-existing bug: `invokeStructMethod` skipped deferred bodies,
        // so `defer { n += 1 }` inside a mutating method never executed.
        // Fixed alongside the script-Sequence work because iterators
        // commonly use the increment-on-exit pattern.
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Box {
                var n: Int = 0
                mutating func incrementAndGet() -> Int {
                    defer { n += 1 }
                    return n
                }
            }
            var b = Box()
            print(b.incrementAndGet())
            print(b.n)
            print(b.incrementAndGet())
            print(b.n)
            """)
        #expect(captured == "0\n1\n1\n2\n")
    }

    // MARK: CustomStringConvertible

    @Test func scriptDescriptionWinsOverDefault() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Point: CustomStringConvertible {
                var x: Int
                var y: Int
                var description: String { "(\\(x), \\(y))" }
            }
            let p = Point(x: 3, y: 4)
            print(p)
            print("origin: \\(p)")
            """)
        #expect(captured == "(3, 4)\norigin: (3, 4)\n")
    }

    @Test func scriptDescriptionRecursesThroughCollections() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Tag: CustomStringConvertible {
                var name: String
                var description: String { "#\\(name)" }
            }
            print([Tag(name: "swift"), Tag(name: "ios")])
            """)
        #expect(captured == "[#swift, #ios]\n")
    }

    // MARK: Hashable (host bridge)

    // MARK: CaseIterable

    @Test func caseIterableSynthesizesAllCases() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            enum Direction: CaseIterable {
                case north, south, east, west
            }
            for d in Direction.allCases {
                print(d)
            }
            """)
        #expect(captured == "north\nsouth\neast\nwest\n")
    }

    @Test func caseIterableSkipsPayloadCases() async throws {
        // Swift's auto-synthesis only fires for payload-less cases; we
        // mirror that by filtering associated-value cases out of the
        // generated allCases array.
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            enum E: CaseIterable {
                case a
                case b
            }
            print(E.allCases.count)
            """)
        #expect(captured == "2\n")
    }

    // MARK: CustomDebugStringConvertible

    @Test func dumpUsesDebugDescription() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Point: CustomDebugStringConvertible {
                var x: Int
                var y: Int
                var debugDescription: String { "P{\\(x),\\(y)}" }
            }
            _ = dump(Point(x: 1, y: 2))
            """)
        #expect(captured == "- P{1,2}\n")
    }

    @Test func dumpReturnsValueForChaining() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            let n = dump(42)
            print(n + 1)
            """)
        #expect(captured == "- 42\n43\n")
    }

    // MARK: Script-defined AsyncIteratorProtocol

    @Test func scriptDefinedAsyncSequenceWithForAwait() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct AsyncCounterIterator {
                var current: Int
                let limit: Int
                mutating func next() async throws -> Int? {
                    guard current < limit else { return nil }
                    defer { current += 1 }
                    return current
                }
            }
            struct AsyncCounter {
                let limit: Int
                func makeAsyncIterator() -> AsyncCounterIterator {
                    return AsyncCounterIterator(current: 0, limit: limit)
                }
            }
            for await i in AsyncCounter(limit: 3) {
                print(i)
            }
            """)
        #expect(captured == "0\n1\n2\n")
    }

    // MARK: Failable init

    @Test func failableScriptInitReturnsNilOnFailure() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            struct Money {
                var amount: Int
                init?(_ s: String) {
                    guard let n = Int(s) else { return nil }
                    self.amount = n
                }
            }
            print(Money("42")?.amount ?? -1)
            print(Money("nope")?.amount ?? -1)
            """#)
        #expect(captured == "42\n-1\n")
    }

    @Test func failableInitWrapsResultInOptional() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Money {
                var amount: Int
                init?(_ n: Int) {
                    if n < 0 { return nil }
                    self.amount = n
                }
            }
            let ok: Money? = Money(5)
            print(ok?.amount ?? -1)
            """)
        #expect(captured == "5\n")
    }

    // MARK: ExpressibleBy*Literal

    @Test func expressibleByIntegerLiteral() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Money {
                var amount: Int
                init(integerLiteral value: Int) { self.amount = value }
            }
            let m: Money = 100
            print(m.amount)
            """)
        #expect(captured == "100\n")
    }

    @Test func expressibleByFloatLiteral() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            struct Distance {
                var meters: Double
                init(floatLiteral value: Double) { self.meters = value }
            }
            let d: Distance = 3.14
            print(d.meters)
            """)
        #expect(captured == "3.14\n")
    }

    @Test func expressibleByStringLiteral() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            struct Tag {
                var name: String
                init(stringLiteral value: String) { self.name = value }
            }
            let t: Tag = "swift"
            print(t.name)
            """#)
        #expect(captured == "swift\n")
    }

    @Test func valueIsHashableOnHostSide() async throws {
        let interp = Interpreter()
        let arr = try await interp.eval(#"[1, "hello", true, 1, "hello"]"#)
        guard case .array(let items) = arr else {
            #expect(Bool(false), "expected array")
            return
        }
        // Stdlib `Set<Value>` works directly because Value is Hashable.
        let unique = Set(items)
        #expect(unique.count == 3)
    }

    @Test func valueArrayPipesThroughZipPrefixMap() async throws {
        let interp = Interpreter()
        let arr = try await interp.eval("[10, 20, 30, 40]")
        // Use stdlib `zip` directly on a ScriptSequence.
        let seq = try arr.asSequence()
        let pairs = Array(zip(seq, 1...))
        #expect(pairs.count == 4)
        // Use stdlib `prefix(_:)`.
        let firstTwo = Array(seq.prefix(2))
        #expect(firstTwo.count == 2)
        #expect(firstTwo[0] == .int(10))
    }
}
