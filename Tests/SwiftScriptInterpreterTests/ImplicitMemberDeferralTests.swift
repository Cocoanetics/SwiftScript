import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Issue #11: a leading-dot member in argument position resolves
/// against the parameter's context type when one is known, and
/// otherwise defers to the callee as an unresolved enum marker so a
/// bridge can decide what `.any` means — the shape a verbatim
/// XCUITest call (`app.descendants(matching: .any)`) needs.
@Suite("Implicit member deferral (issue #11)")
struct ImplicitMemberDeferralTests {

    /// A bridge that receives a leading-dot argument by *case name*,
    /// exactly as an element-query API would consume `.any`.
    private struct FakeQueryModule: BuiltinModule {
        let name = "FakeQuery"
        func register(into i: Interpreter) {
            i.bridges["init Query()"] = .`init` { _ in
                .opaque(typeName: "Query", value: "root")
            }
            // `query.descendants(matching: .any)` — the arg arrives as
            // the deferred marker `.enumValue(typeName: "", caseName:)`.
            i.bridges["func Query.descendants()"] = .method { receiver, args in
                guard case .opaque(_, let base as String) = receiver else {
                    throw RuntimeError.invalid("Query.descendants: bad receiver")
                }
                guard args.count == 1,
                      case .enumValue(_, let caseName, _) = args[0]
                else {
                    throw RuntimeError.invalid(
                        "Query.descendants(matching:): expected an element-type case")
                }
                return .opaque(typeName: "Query", value: "\(base)/\(caseName)")
            }
            i.bridges["var Query.identifier"] = .computed { receiver in
                guard case .opaque(_, let id as String) = receiver else {
                    throw RuntimeError.invalid("Query.identifier: bad receiver")
                }
                return .string(id)
            }
        }
    }

    @Test func bareMemberArgumentDefersToBridge() async throws {
        let interp = Interpreter()
        interp.registerOnImport("FakeQuery", module: FakeQueryModule())
        let r = try await interp.eval(#"""
            import FakeQuery
            Query().descendants(matching: .any).identifier
            """#)
        #expect(r == .string("root/any"))
    }

    @Test func differentBareMembersReachTheBridge() async throws {
        let interp = Interpreter()
        interp.registerOnImport("FakeQuery", module: FakeQueryModule())
        let r = try await interp.eval(#"""
            import FakeQuery
            Query().descendants(matching: .button).identifier
            """#)
        #expect(r == .string("root/button"))
    }

    // MARK: - Existing contextual resolution is unchanged

    @Test func bridgeStaticLetContextStillResolves() async throws {
        // `.whitespaces` still resolves to `CharacterSet.whitespaces`
        // via the parameter's implicit-member context, not the marker.
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            "  hi  ".trimmingCharacters(in: .whitespaces)
            """#)
        #expect(r == .string("hi"))
    }

    @Test func encodingContextStillResolves() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            String(data: Data("bytes".utf8), encoding: .utf8)!
            """#)
        #expect(r == .string("bytes"))
    }

    @Test func optionSetArrayLiteralStillResolves() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            let out = try JSONSerialization.data(withJSONObject: ["b": 2, "a": 1], options: [.sortedKeys])
            String(data: out, encoding: .utf8)!
            """#)
        #expect(r == .string(#"{"a":1,"b":2}"#))
    }

    @Test func userEnumArgumentStillResolves() async throws {
        // User-function args resolve against the declared enum type.
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum Color { case red, green }
            func name(_ c: Color) -> String {
                switch c { case .red: return "red"; case .green: return "green" }
            }
            name(.green)
            """#)
        #expect(r == .string("green"))
    }

    // MARK: - General position stays a hard error

    @Test func bareMemberInGeneralPositionStillThrows() async throws {
        // A leading-dot member outside argument position has no callee
        // to defer to, so it must remain a loud error rather than
        // silently producing a marker.
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("let x = .any")
        }
    }

    // MARK: - Builtin containers keep the hard error (no silent deferral)

    @Test func bareMemberToBuiltinArrayMethodStillThrows() async throws {
        // The receiver is a builtin `[Int]`, not a bridged type — there
        // is no bridge to interpret `.foo`, so it must stay the same
        // "no such member" error stock Swift gives, not silently
        // compare a marker that never matches (which would make
        // `contains` return false).
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("[1, 2, 3].contains(.foo)")
        }
    }

    @Test func bareMemberToBuiltinFirstIndexStillThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval("[1, 2, 3].firstIndex(of: .bar)")
        }
    }

    @Test func bareMemberToBuiltinSetStillThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: RuntimeError.self) {
            _ = try await interp.eval(#"""
                import Foundation
                Set([1, 2, 3]).contains(.foo)
                """#)
        }
    }
}
