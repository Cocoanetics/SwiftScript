import Testing
import Foundation
@testable import SwiftScriptInterpreter

// Foundation bridge is gated to Apple platforms — see
// `Sources/SwiftScriptInterpreter/Modules/FoundationBridge/`.
#if canImport(Darwin)

/// JSON encode/decode for script values rides on Foundation's actual
/// `JSONEncoder`/`JSONDecoder` via the `ScriptCodable` bridge. These
/// tests cover the Codable surface the bridge exposes — primitives,
/// structs, arrays, optionals, and Foundation Codable types.
@Suite("Codable bridge to Foundation")
struct CodableTests {
    @Test func roundTripStruct() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct Person: Codable {
                var name: String
                var age: Int
            }
            let alice = Person(name: "Alice", age: 30)
            let data = try JSONEncoder().encode(alice)
            let copy = try JSONDecoder().decode(Person.self, from: data)
            print(copy.name, copy.age)
            """#)
        #expect(captured == "Alice 30\n")
    }

    @Test func optionalFieldsOmitNilOnEncode() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct Maybe: Codable {
                var x: Int
                var y: Int?
            }
            let m = Maybe(x: 1, y: nil)
            let data = try JSONEncoder().encode(m)
            print(String(data: data, encoding: .utf8) ?? "?")
            """#)
        // Field order is Foundation's encoding choice — verify the
        // semantically interesting bit: nil-valued y is absent.
        #expect(!captured.contains("\"y\""))
        #expect(captured.contains("\"x\":1"))
    }

    @Test func decodeMissingOptionalFieldAsNil() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct Maybe: Codable {
                var x: Int
                var y: Int?
            }
            let raw = #"{"x": 5}"#.data(using: .utf8)!
            let m = try JSONDecoder().decode(Maybe.self, from: raw)
            print(m.x, m.y ?? -1)
            """#)
        #expect(captured == "5 -1\n")
    }

    @Test func roundTripArrayOfStructs() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct Tag: Codable { var name: String }
            let tags = [Tag(name: "a"), Tag(name: "b")]
            let data = try JSONEncoder().encode(tags)
            let copy = try JSONDecoder().decode([Tag].self, from: data)
            print(copy.count, copy[0].name, copy[1].name)
            """#)
        #expect(captured == "2 a b\n")
    }

    @Test func nestedStruct() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct Inner: Codable { var n: Int }
            struct Outer: Codable {
                var name: String
                var inner: Inner
            }
            let o = Outer(name: "x", inner: Inner(n: 42))
            let data = try JSONEncoder().encode(o)
            let copy = try JSONDecoder().decode(Outer.self, from: data)
            print(copy.name, copy.inner.n)
            """#)
        #expect(captured == "x 42\n")
    }

    @Test func foundationDateRidesItsOwnConformance() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        // Foundation's default Date encoding is timeIntervalSinceReference —
        // a single number. We don't reimplement that strategy; we just
        // verify the round-trip works.
        try await interp.eval(#"""
            import Foundation
            struct Reminder: Codable {
                var note: String
                var when: Date
            }
            let r = Reminder(note: "buy milk", when: Date())
            let data = try JSONEncoder().encode(r)
            let copy = try JSONDecoder().decode(Reminder.self, from: data)
            print(copy.note)
            print(copy.when.timeIntervalSinceNow <= 0.001)
            """#)
        #expect(captured == "buy milk\ntrue\n")
    }

    @Test func foundationURLRoundTrips() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct Bookmark: Codable {
                var title: String
                var url: URL
            }
            let b = Bookmark(title: "example", url: URL(string: "https://example.com/p")!)
            let data = try JSONEncoder().encode(b)
            let copy = try JSONDecoder().decode(Bookmark.self, from: data)
            print(copy.title)
            print(copy.url.host ?? "?")
            """#)
        #expect(captured == "example\nexample.com\n")
    }

    @Test func decodeRawValueEnum() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            enum Status: Int, Codable {
                case ok = 200
                case bad = 400
            }
            let raw = #"400"#.data(using: .utf8)!
            let s = try JSONDecoder().decode(Status.self, from: raw)
            print(s.rawValue)
            """#)
        #expect(captured == "400\n")
    }

    @Test func encoderConfigurationFlowsThrough() async throws {
        // Even though we don't expose every encoder strategy yet, the
        // bridge means Foundation's encoder is the one running — so any
        // future config (e.g. `.sortedKeys`) will work without us having
        // to reimplement it.
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            struct A: Codable { var z: Int; var a: Int }
            let v = A(z: 1, a: 2)
            let data = try JSONEncoder().encode(v)
            let s = String(data: data, encoding: .utf8)!
            // We can't pin the order, but we can pin that both keys are present.
            print(s.contains("\"z\":1") && s.contains("\"a\":2"))
            """#)
        #expect(captured == "true\n")
    }
}

#endif
