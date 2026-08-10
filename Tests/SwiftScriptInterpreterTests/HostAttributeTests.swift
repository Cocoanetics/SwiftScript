import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Issue #14, attached half: a host can register attribute names it
/// understands (`@Test`, `@Suite`), the preflight stops refusing them,
/// and the declarations carrying them become enumerable — with their
/// arguments as `Value`s — and, for functions, invocable.
@Suite("Host-registered attributes (issue #14)")
struct HostAttributeTests {

    @Test func unregisteredAttributeStaysRefused() async throws {
        let interp = Interpreter()
        do {
            _ = try await interp.eval("@Test func f() {}")
            Issue.record("expected the preflight to refuse '@Test'")
        } catch let err as RuntimeError {
            #expect(err.description.contains("attribute '@Test'"))
        }
    }

    @Test func registeredAttributeLoadsAndEnumerates() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerAttribute("Test")
        _ = try await interp.eval("""
            @Test func loginWorks() async throws {
                print("ran")
            }
            """)
        let tests = interp.declarations(withAttribute: "Test")
        #expect(tests.count == 1)
        #expect(tests[0].name == "loginWorks")
        #expect(tests[0].arguments.isEmpty)
        let invocable = try #require(tests[0].invocable)
        _ = try await interp.call(invocable)
        #expect(out == "ran\n")
    }

    @Test func displayNameArgument() async throws {
        let interp = Interpreter()
        interp.registerAttribute("Test")
        _ = try await interp.eval("""
            @Test("the display name") func f() {}
            """)
        let tests = interp.declarations(withAttribute: "Test")
        #expect(tests[0].arguments.count == 1)
        #expect(tests[0].arguments[0].label == nil)
        #expect(tests[0].arguments[0].value == .string("the display name"))
        #expect(tests[0].arguments[0].sourceText == #""the display name""#)
    }

    @Test func implicitMemberArgumentsDeferToHost() async throws {
        // `.disabled("flaky")` / `.tags(.critical)` — the attribute's
        // parameter types live on the host, so implicit members arrive
        // as unresolved markers, nested ones included.
        let interp = Interpreter()
        interp.registerAttribute("Test")
        _ = try await interp.eval("""
            @Test(.disabled("flaky"), .tags(.critical)) func f() {}
            """)
        let args = interp.declarations(withAttribute: "Test")[0].arguments
        #expect(args.count == 2)
        #expect(args[0].value == .enumValue(
            typeName: "", caseName: "disabled",
            associatedValues: [.string("flaky")]
        ))
        #expect(args[1].value == .enumValue(
            typeName: "", caseName: "tags",
            associatedValues: [.enumValue(typeName: "", caseName: "critical", associatedValues: [])]
        ))
    }

    @Test func parameterizedTestArgumentsAndInvocation() async throws {
        var out = ""
        let interp = Interpreter(output: { out += $0 })
        interp.registerAttribute("Test")
        _ = try await interp.eval("""
            @Test(arguments: [1, 2, 3]) func doubles(_ n: Int) {
                print(n * 2)
            }
            """)
        let tests = interp.declarations(withAttribute: "Test")
        #expect(tests[0].arguments.count == 1)
        #expect(tests[0].arguments[0].label == "arguments")
        #expect(tests[0].arguments[0].value == .array([.int(1), .int(2), .int(3)]))
        // The host drives the parameterized run.
        guard case .array(let cases)? = tests[0].arguments.first?.value else {
            Issue.record("expected an array argument")
            return
        }
        let invocable = try #require(tests[0].invocable)
        for c in cases {
            _ = try await interp.call(invocable, arguments: [c])
        }
        #expect(out == "2\n4\n6\n")
    }

    @Test func suiteTypeIsRecordedWithoutInvocable() async throws {
        let interp = Interpreter()
        interp.registerAttribute("Suite")
        interp.registerAttribute("Test")
        _ = try await interp.eval("""
            @Suite("Login") struct LoginTests {
                @Test func placeholder() {}
            }
            """)
        let suites = interp.declarations(withAttribute: "Suite")
        #expect(suites.count == 1)
        #expect(suites[0].name == "LoginTests")
        #expect(suites[0].arguments.first?.value == .string("Login"))
        #expect(suites[0].invocable == nil)
        // Methods inside suite types aren't enumerated yet — only the
        // suite itself. (Top-level `@Test func`s are the enumerable
        // form; see registeredAttributeLoadsAndEnumerates.)
        #expect(interp.declarations(withAttribute: "Test").isEmpty)
    }

    @Test func suiteEnumIsRecorded() async throws {
        // Swift Testing allows enums as suite containers — the enum
        // path records registered attributes like structs and classes.
        let interp = Interpreter()
        interp.registerAttribute("Suite")
        _ = try await interp.eval("""
            @Suite enum Fixtures {}
            """)
        let suites = interp.declarations(withAttribute: "Suite")
        #expect(suites.map(\.name) == ["Fixtures"])
        #expect(suites[0].invocable == nil)
    }

    @Test func reEvaluationReplacesInsteadOfDuplicating() async throws {
        let interp = Interpreter()
        interp.registerAttribute("Test")
        let source = "@Test func f() {}"
        _ = try await interp.eval(source)
        _ = try await interp.eval(source)
        #expect(interp.declarations(withAttribute: "Test").count == 1)
    }

    // MARK: - The issue's end-to-end shape

    @Test func swiftTestingFileRunsUnmodified() async throws {
        // The point of issue #14: paste a Swift Testing-shaped file in,
        // enumerate its tests, run them, and collect expectation
        // failures with source text — `#expect` records and continues,
        // `#require` throws.
        let interp = Interpreter()
        var issues: [String] = []
        interp.registerMacro("expect") { args in
            if args[0].value == .bool(false) {
                issues.append("Expectation failed: \(args[0].sourceText)")
            }
            return .void
        }
        interp.registerMacro("require") { args in
            if case .optional(let inner) = args[0].value {
                guard let inner else {
                    throw RuntimeError.invalid("Expectation failed: \(args[0].sourceText)")
                }
                return inner
            }
            return args[0].value
        }
        interp.registerAttribute("Test")
        _ = try await interp.eval("""
            import Testing

            @Test func math() async throws {
                #expect(1 + 1 == 3)
                let n = try #require(Int("21"))
                #expect(n * 2 == 42)
            }
            """)
        let tests = interp.declarations(withAttribute: "Test")
        #expect(tests.map(\.name) == ["math"])
        _ = try await interp.call(try #require(tests[0].invocable))
        // The failing expectation was recorded, the run continued, and
        // the passing ones stayed quiet.
        #expect(issues == ["Expectation failed: 1 + 1 == 3"])
    }
}
