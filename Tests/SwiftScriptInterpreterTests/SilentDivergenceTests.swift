import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Regression coverage for issue #8: constructs that used to return
/// a *plausible wrong value* instead of either the stock-Swift answer
/// or a loud error.
@Suite("Silent divergences (issue #8)")
struct SilentDivergenceTests {

    // MARK: - String code-unit views

    @Test func utf8CountIsByteCount() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#""héllo".utf8.count"#)
        #expect(r == .int(6))
    }

    @Test func utf16AndScalarCounts() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            ("héllo".utf16.count, "héllo".unicodeScalars.count, "🇦🇷".utf16.count)
            """#)
        #expect(r == .tuple([.int(5), .int(5), .int(4)]))
    }

    @Test func utf8IteratesBytes() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            var sum = 0
            for b in "abc".utf8 { sum += Int(b) }
            sum
            """#)
        #expect(r == .int(294))
    }

    @Test func unicodeScalarValue() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#""é".unicodeScalars.first!.value"#)
        #expect(r == .int(233))
    }

    @Test func dataFromUTF8ViewStillWorks() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            Data("hi".utf8).count
            """#)
        #expect(r == .int(2))
    }

    // MARK: - `as?` through Optional

    @Test func castThroughOptionalUnwraps() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let dict: [String: Any] = ["k": 1]
            dict["k"] as? Int
            """#)
        #expect(r == .optional(.int(1)))
    }

    @Test func castThroughOptionalNilStaysNil() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let dict: [String: Any] = ["k": 1]
            dict["missing"] as? Int
            """#)
        #expect(r == .optional(nil))
    }

    @Test func forcedCastUnwrapsOptional() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let x: Int? = 5
            x as! Int
            """#)
        #expect(r == .int(5))
    }

    @Test func switchCaseAsMatchesBoxedOptional() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let dict: [String: Any] = ["k": 7]
            switch dict["k"] as Any {
            case let i as Int: "int \(i)"
            default: "other"
            }
            """#)
        #expect(r == .string("int 7"))
    }

    // MARK: - Element-typed collection casts

    @Test func arrayCastChecksElementTypes() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let xs: [Any] = ["a", "b"]
            (xs as? [Int], xs as? [String], ([] as [Any]) as? [Int])
            """#)
        guard case .tuple(let parts, _) = r else {
            Issue.record("expected tuple, got \(r)")
            return
        }
        #expect(parts[0] == .optional(nil))
        #expect(parts[1] == .optional(.array([.string("a"), .string("b")])))
        if case .optional(.some(.array(let empty))) = parts[2] {
            #expect(empty.isEmpty)
        } else {
            Issue.record("empty array should cast to any element type, got \(parts[2])")
        }
    }

    @Test func dictCastChecksValueTypes() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let d: [String: Any] = ["a": 1, "b": "two"]
            (d as? [String: Int], d as? [String: Any])
            """#)
        guard case .tuple(let parts, _) = r else {
            Issue.record("expected tuple, got \(r)")
            return
        }
        #expect(parts[0] == .optional(nil))
        #expect(parts[1] != .optional(nil))
    }

    // MARK: - Unsupported attributes fail loudly

    private func expectUnsupportedAttribute(
        _ source: String,
        containing needle: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let interp = Interpreter()
        do {
            _ = try await interp.eval(source)
            Issue.record(
                "expected unsupported-attribute error, script ran",
                sourceLocation: sourceLocation)
        } catch let error as RuntimeError {
            #expect(
                "\(error)".contains(needle),
                "unexpected error: \(error)",
                sourceLocation: sourceLocation)
        } catch {
            Issue.record(
                "expected RuntimeError, got \(error)",
                sourceLocation: sourceLocation)
        }
    }

    @Test func propertyWrapperDeclarationIsRefused() async {
        await expectUnsupportedAttribute(#"""
            @propertyWrapper
            struct Clamped {
                var wrappedValue: Int
            }
            """#, containing: "@propertyWrapper")
    }

    @Test func resultBuilderDeclarationIsRefused() async {
        await expectUnsupportedAttribute(#"""
            @resultBuilder
            struct B { static func buildBlock(_ s: String...) -> String { s.joined() } }
            """#, containing: "@resultBuilder")
    }

    @Test func customAttributeUseIsRefused() async {
        await expectUnsupportedAttribute(#"""
            struct S { @Clamped var x: Int = 5 }
            """#, containing: "@Clamped")
    }

    @Test func benignAttributesStillRun() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            @discardableResult
            func f() -> Int { 1 }
            f()
            @available(macOS 10.15, *)
            func g() -> Int { 2 }
            g()
            """#)
        #expect(r == .int(2))
    }

    @Test func typePositionAttributesStillRun() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func run(_ body: @escaping () -> Int) -> Int { body() }
            run { 3 }
            """#)
        #expect(r == .int(3))
    }

    @Test func unknownDefaultAttributeIsAccepted() async throws {
        // `@unknown default:` is a switch-case attribute, not a
        // declaration attribute — it has no runtime semantics and
        // stock Swift accepts it, so the preflight must not reject it.
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum E { case a, b }
            func f(_ e: E) -> String {
                switch e {
                case .a: return "a"
                case .b: return "b"
                @unknown default: return "?"
                }
            }
            f(.a)
            """#)
        #expect(r == .string("a"))
    }
}
