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
