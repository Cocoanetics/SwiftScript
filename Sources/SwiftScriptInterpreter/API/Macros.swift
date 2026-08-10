import SwiftSyntax

// MARK: - Host-registered macros and attributes (issue #14)
//
// Freestanding macros (`#expect(a == b)`) and attached attributes
// (`@Test func …`) cannot be modelled as ordinary functions: the whole
// point of the macro form is access to the *source text* of its
// arguments, and the whole point of an attribute is that somebody
// else — the host — enumerates the declarations carrying it. Neither
// has interpreter-side semantics; both dispatch to whatever the host
// registered. Unregistered names stay hard errors, matching stock
// Swift ("no macro named 'x'"; unknown-attribute preflight refusal).

/// One evaluated argument of a freestanding-macro expansion or of a
/// registered attribute's argument list.
///
/// `value` is what the handler needs for its verdict; `sourceText` is
/// the exact source spelling of the argument expression, which is what
/// a `#expect`-shaped handler needs to build its failure message
/// ("Expectation failed: a == b"). `label` carries the argument label
/// (`sourceLocation:` / `arguments:`), `nil` for unlabeled positions
/// and for a plain trailing closure.
public struct MacroArgument {
    public let label: String?
    public let value: Value
    public let sourceText: String

    public init(label: String?, value: Value, sourceText: String) {
        self.label = label
        self.value = value
        self.sourceText = sourceText
    }
}

/// A declaration observed carrying a host-registered attribute — what
/// turns "a script" into "a test file the runner enumerates and runs".
public struct AttributedDeclaration {
    /// Attribute name without the `@` — `"Test"`, `"Suite"`.
    public let attribute: String
    /// Declared name — the function name for `@Test func loginWorks()`,
    /// the type name for `@Suite struct LoginTests`.
    public let name: String
    /// The attribute's arguments (`@Test("display name")`,
    /// `@Test(.disabled("flaky"))`, `@Test(arguments: [1, 2, 3])`),
    /// evaluated at declaration time. Implicit-member forms
    /// (`.disabled(…)`) have no type the interpreter could resolve
    /// against, so they arrive as unresolved enum markers
    /// (`typeName: ""`) — the host decides what they mean, the same
    /// defer-to-the-callee rule issue #13 established for leading-dot
    /// call arguments.
    public let arguments: [MacroArgument]
    /// The declared function wrapped as a callable `.function` value —
    /// hand it to ``Interpreter/call(_:arguments:)`` to run the test.
    /// `nil` when the attribute sits on a type declaration.
    public let invocable: Value?
}

extension Interpreter {
    /// Register a handler for the freestanding macro `#name(…)`.
    /// `name` is spelled without the `#`. Stored in the bridge table
    /// under `"macro #name"`, so modules can equally write
    /// `bridges["macro #expect"] = .macro { … }`.
    ///
    /// The handler receives every argument evaluated *and* as source
    /// text — see ``MacroArgument``. A handler that records an issue
    /// and returns `.void` gives `#expect` semantics (record and
    /// continue); one that throws gives `#require` semantics (record
    /// and abort — the thrown error is catchable by script
    /// `do`/`catch`, and `try #require(…)` renders naturally).
    public func registerMacro(
        _ name: String,
        body: @escaping ([MacroArgument]) async throws -> Value
    ) {
        bridges[bridgeKey(forMacro: name)] = .macro(body)
    }

    /// Declare that the host understands the attached attribute
    /// `@name`. The unsupported-attribute preflight stops refusing it,
    /// and declarations carrying it are recorded for
    /// ``declarations(withAttribute:)``. Spelled without the `@`.
    public func registerAttribute(_ name: String) {
        registeredAttributes.insert(name)
    }

    /// Declarations observed (so far) carrying the registered
    /// attribute `@name`, in execution order. Re-evaluating a
    /// declaration with the same name replaces its earlier entry, the
    /// same way re-declaring a function rebinds it.
    public func declarations(withAttribute name: String) -> [AttributedDeclaration] {
        attributedDeclarations.filter { $0.attribute == name }
    }

    /// Invoke a script-side `.function` value from host code — the
    /// counterpart of ``AttributedDeclaration/invocable``. Arguments
    /// are bound positionally, the way the internal call machinery
    /// binds them for closures.
    @discardableResult
    public func call(_ function: Value, arguments: [Value] = []) async throws -> Value {
        guard case .function(let fn) = function else {
            throw RuntimeError.invalid(
                "cannot call value of non-function type '\(typeName(function))'"
            )
        }
        return try await invoke(fn, args: arguments)
    }
}
