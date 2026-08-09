import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Regressions for the ten defects an adversarial review found in the
/// #7/#8/#9 work — silent divergences and correctness bugs in the new
/// bridge surface. (The two sandbox escapes it also found are covered
/// in ConfinedSandboxTests.)
@Suite("Bridge review regressions")
struct BridgeReviewRegressionTests {

    // MARK: `x as Any` keeps the Optional wrapper

    @Test func asAnyPreservesOptional() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let v: Int? = 5
            "\(v as Any)"
            """#)
        #expect(r == .string("Optional(5)"))
    }

    @Test func asAnyOnDictLookupStaysWrapped() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let d: [String: Any] = ["a": 1]
            "\(d["a"] as Any)"
            """#)
        #expect(r == .string("Optional(1)"))
    }

    // MARK: numeric cross-casts (JSON/NSNumber idiom)

    @Test func intCastsToDouble() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("(1 as Any) as? Double")
        #expect(r == .optional(.double(1.0)))
    }

    @Test func integralDoubleCastsToInt() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("(2.0 as Any) as? Int")
        #expect(r == .optional(.int(2)))
    }

    @Test func nonIntegralDoubleDoesNotCastToInt() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("(2.5 as Any) as? Int")
        #expect(r == .optional(nil))
    }

    // MARK: JSONSerialization

    @Test func jsonNumberCastsToDouble() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            let j = try JSONSerialization.jsonObject(with: Data(#"{"p": 19}"#.utf8)) as! [String: Any]
            j["p"] as? Double
            """#)
        #expect(r == .optional(.double(19.0)))
    }

    @Test func jsonUnsignedOverflowDoesNotWrap() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            let j = try JSONSerialization.jsonObject(with: Data(#"{"n": 18446744073709551615}"#.utf8)) as! [String: Any]
            j["n"] as? Int == nil
            """#)
        #expect(r == .bool(true))
    }

    @Test func jsonWritingOptionsArrayLiteralHonored() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            let out = try JSONSerialization.data(withJSONObject: ["b": 2, "a": 1], options: [.sortedKeys])
            String(data: out, encoding: .utf8)!
            """#)
        #expect(r == .string(#"{"a":1,"b":2}"#))
    }

    @Test func jsonFragmentRejectedWithoutOption() async throws {
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                try JSONSerialization.jsonObject(with: Data("42".utf8))
                """#)
        }
    }

    // MARK: numeric-conversion inits

    @Test func fixedWidthNumericInits() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            (Int(UInt8(3)), Int(Int32(7)), Int(UInt16(9)))
            """#)
        #expect(r == .tuple([.int(3), .int(7), .int(9)]))
    }

    @Test func numericInitOverflowThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                UInt8(300)
                """#)
        }
    }

    @Test func numericStringInitStaysFailable() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            (UInt8("42"), UInt8("nope"))
            """#)
        #expect(r == .tuple([.optional(.int(42)), .optional(nil)]))
    }

    // MARK: Data.append byte overload + absolute slice indices

    @Test func dataAppendByteAndData() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            var d = Data([1])
            d.append(3)
            d.append(Data([9]))
            d.append(contentsOf: [7])
            (d.count, d[0], d[1], d[2], d[3])
            """#)
        #expect(r == .tuple([.int(4), .int(1), .int(3), .int(9), .int(7)]))
    }

    // MARK: mutating methods through a member-access l-value

    @Test func mutatingMethodThroughClassProperty() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            class Holder { var data = Data([1]) }
            let h = Holder()
            h.data.append(2)
            h.data.append(Data([9]))
            (h.data.count, h.data[0], h.data[1], h.data[2])
            """#)
        #expect(r == .tuple([.int(3), .int(1), .int(2), .int(9)]))
    }

    @Test func mutatingMethodThroughStructProperty() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            struct Box { var req = URLRequest(url: URL(string: "https://x.y")!) }
            var b = Box()
            b.req.setValue("v", forHTTPHeaderField: "K")
            b.req.value(forHTTPHeaderField: "K")!
            """#)
        #expect(r == .string("v"))
    }
}
