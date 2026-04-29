import Testing
@testable import SwiftScriptInterpreter

/// Each test pairs a script-side call shape with the swiftc diagnostic
/// it should produce. The expected strings are taken verbatim from
/// `swiftc -typecheck` output for an equivalent function (see
/// `Tools/swiftc-error-probes.sh` if it ever drifts).
@Suite("Call validator (swiftc-shaped errors)")
struct CallValidatorTests {

    // sig matches `func f(_ x: Int, y: String) {}`
    static let twoArg = CallSignature(name: "f", parameters: [
        .init(label: nil, name: "x", type: .int),
        .init(label: "y", name: "y", type: .string),
    ])

    // sig matches `func f(_ x: Int, y: String, z: Bool = false) {}`
    static let withDefault = CallSignature(name: "f", parameters: [
        .init(label: nil, name: "x", type: .int),
        .init(label: "y", name: "y", type: .string),
        .init(label: "z", name: "z", type: .bool, hasDefault: true),
    ])

    // sig matches `func f() {}`
    static let noArgs = CallSignature(name: "f", parameters: [])

    @Test func valid_call_passes() throws {
        try validate(arguments: [
            CallArgument(label: nil, value: .int(1)),
            CallArgument(label: "y", value: .string("a")),
        ], against: Self.twoArg)
    }

    @Test func valid_call_with_default_omitted() throws {
        try validate(arguments: [
            CallArgument(label: nil, value: .int(1)),
            CallArgument(label: "y", value: .string("a")),
        ], against: Self.withDefault)
    }

    @Test func missing_argument_for_parameter() {
        // `f(1)` against `(_:y:)` → swiftc:
        //   missing argument for parameter 'y' in call
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
            ], against: Self.twoArg)
        }
        #expect(err == "missing argument for parameter 'y' in call")
    }

    @Test func missing_argument_label() {
        // `f(1, "a")` against `(_:y:)` → swiftc:
        //   missing argument label 'y:' in call
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
                CallArgument(label: nil, value: .string("a")),
            ], against: Self.twoArg)
        }
        #expect(err == "missing argument label 'y:' in call")
    }

    @Test func extra_labelled_argument() {
        // `f(1, y: "a", z: 2)` against `(_:y:)` → swiftc:
        //   extra argument 'z' in call
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
                CallArgument(label: "y", value: .string("a")),
                CallArgument(label: "z", value: .int(2)),
            ], against: Self.twoArg)
        }
        #expect(err == "extra argument 'z' in call")
    }

    @Test func extra_unlabelled_argument() {
        // `f(1, "a", 2)` against `(_:y:)` → swiftc:
        //   extra argument in call (after the `y:` label fix-up)
        // Here we model the post-label-fixup state directly.
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
                CallArgument(label: "y", value: .string("a")),
                CallArgument(label: nil, value: .int(2)),
            ], against: Self.twoArg)
        }
        #expect(err == "extra argument in call")
    }

    @Test func incorrect_label() {
        // `f(1, x: "a")` against `(_:y:)` → swiftc:
        //   incorrect argument label in call (have '_:x:', expected '_:y:')
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
                CallArgument(label: "x", value: .string("a")),
            ], against: Self.twoArg)
        }
        #expect(err == "incorrect argument label in call (have '_:x:', expected '_:y:')")
    }

    @Test func type_mismatch_int_for_string() {
        // `f(1, y: 99)` against `(_:y: String)` → swiftc:
        //   cannot convert value of type 'Int' to expected argument type 'String'
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
                CallArgument(label: "y", value: .int(99)),
            ], against: Self.twoArg)
        }
        #expect(err == "cannot convert value of type 'Int' to expected argument type 'String'")
    }

    @Test func type_mismatch_string_for_int() {
        // `f("a", y: "b")` against `(_: Int, y: String)` → swiftc:
        //   cannot convert value of type 'String' to expected argument type 'Int'
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .string("a")),
                CallArgument(label: "y", value: .string("b")),
            ], against: Self.twoArg)
        }
        #expect(err == "cannot convert value of type 'String' to expected argument type 'Int'")
    }

    @Test func no_args_allowed() {
        // `f(1)` against `()` → swiftc:
        //   argument passed to call that takes no arguments
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: nil, value: .int(1)),
            ], against: Self.noArgs)
        }
        #expect(err == "argument passed to call that takes no arguments")
    }

    @Test func int_promotes_to_double() throws {
        let sig = CallSignature(name: "f", parameters: [
            .init(label: nil, name: "x", type: .double),
        ])
        // Int → Double should pass type check.
        try validate(arguments: [
            CallArgument(label: nil, value: .int(7)),
        ], against: sig)
    }

    @Test func value_promotes_to_optional() throws {
        let sig = CallSignature(name: "f", parameters: [
            .init(label: nil, name: "x", type: .optional(.string)),
        ])
        try validate(arguments: [
            CallArgument(label: nil, value: .string("hi")),
        ], against: sig)
        try validate(arguments: [
            CallArgument(label: nil, value: .optional(nil)),
        ], against: sig)
    }

    @Test func opaque_type_match() throws {
        let sig = CallSignature(name: "f", parameters: [
            .init(label: "from", name: "url", type: .opaque("URL")),
        ])
        try validate(arguments: [
            CallArgument(label: "from",
                         value: .opaque(typeName: "URL", value: "irrelevant")),
        ], against: sig)
    }

    @Test func opaque_type_mismatch() {
        let sig = CallSignature(name: "f", parameters: [
            .init(label: "from", name: "url", type: .opaque("URL")),
        ])
        let err = expectThrow {
            try validate(arguments: [
                CallArgument(label: "from",
                             value: .opaque(typeName: "Date", value: "irrelevant")),
            ], against: sig)
        }
        #expect(err == "cannot convert value of type 'Date' to expected argument type 'URL'")
    }
}

/// Run `body`, expecting a throw, return the error's `description`.
private func expectThrow(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "<no error thrown>"
    } catch {
        return String(describing: error)
    }
}
