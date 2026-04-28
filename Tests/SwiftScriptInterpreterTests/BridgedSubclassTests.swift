import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Script classes that "subclass" a bridged Foundation type are modeled
/// as wrappers: the instance holds both script fields and a real native
/// value (`bridgedBase`). Member lookup falls through to the bridged
/// surface for anything the script doesn't override.
@Suite("Bridged-type subclass wrapper")
struct BridgedSubclassTests {
    @Test func tagAFoundationDate() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            import Foundation
            class TaggedDate: Date {
                var label: String = ""
            }
            let d = TaggedDate()
            d.label = "deadline"
            print(d.label)
            // Bridged property reachable via fallback dispatch
            print(d.timeIntervalSinceNow <= 0.001)
            """)
        #expect(captured == "deadline\ntrue\n")
    }

    @Test func failableBridgedInitPropagates() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            class LabeledURL: URL {
                var label: String = ""
            }
            let u = LabeledURL(string: "https://example.com/p")!
            u.label = "homepage"
            print(u.label)
            print(u.host ?? "?")
            print(u.path)
            """#)
        #expect(captured == "homepage\nexample.com\n/p\n")
    }

    @Test func wrapperSatisfiesIsCheckForBridgedParent() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            import Foundation
            class TaggedDate: Date {
                var label: String = ""
            }
            let d = TaggedDate()
            print(d is Date)
            """)
        #expect(captured == "true\n")
    }

    @Test func failableInitReturnsNilOnFailure() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval(#"""
            import Foundation
            class LabeledURL: URL {
                var label: String = ""
            }
            let u = LabeledURL(string: "")
            print(u == nil)
            """#)
        #expect(captured == "true\n")
    }
}
