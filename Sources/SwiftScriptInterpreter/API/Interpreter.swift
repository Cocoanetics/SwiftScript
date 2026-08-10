import SwiftSyntax
import SwiftScriptAST
import ShellKit

/// `@unchecked Sendable`: the interpreter holds extensive mutable state
/// (scopes, bridge tables, struct/class/enum defs) and is **not**
/// thread-safe in any meaningful sense. The conformance is here so
/// callers in async / nonisolated contexts can hop the interpreter
/// across suspension points without tripping Swift 6 strict-concurrency
/// checks. The contract is the usual one: one logical caller at a
/// time. A script is single-threaded; concurrency inside the script
/// (`Task { … }`, async bridges) goes through the same instance from
/// the same logical owner.
public final class Interpreter: @unchecked Sendable {
    public let rootScope: Scope

    /// Where script-emitted text goes — every `print`, `dump`, and
    /// any other stdout-style write. The closure receives the
    /// **verbatim** bytes the script wrote, including any trailing
    /// newline `print` chose to add. Set this to capture or redirect.
    ///
    /// **Default behaviour** routes through ``ShellKit/Shell/current``'s
    /// stdout sink. Standalone (`swift-script foo.swift`) that means
    /// real fd 1 (`Shell.processDefault.stdout`); under an embedder
    /// (SwiftBash, an iOS app) it means whatever sink the embedder
    /// has bound for the current task. Same code path, different
    /// destinations — no separate plumbing needed for capture.
    public var output: (String) -> Void

    /// Where parse errors and runtime-error renders go — the
    /// stderr-shaped channel. Same verbatim-text contract as
    /// ``output``. Defaults to ``ShellKit/Shell/current``'s stderr
    /// sink so embedder capture / sandbox routing works out of
    /// the box.
    public var error: (String) -> Void

    /// Stack of declared return types for the currently-active user function
    /// calls. Used by `return` statements (and implicit returns) to coerce
    /// the produced value against the function's declared return type.
    var returnTypeStack: [TypeSyntax?] = []

    /// Registered struct definitions keyed by type name. Populated by
    /// `struct Foo { … }` declarations and consulted at call sites that look
    /// like `Foo(x:)`, plus member/method accesses on struct instances.
    var structDefs: [String: StructDef] = [:]

    /// Registered class definitions keyed by type name. Tracked separately
    /// from `structDefs` because dispatch differs (reference semantics,
    /// inheritance chain, no `mutating` modifier required) — but lookups
    /// often need to consult both, so callers grep both maps.
    var classDefs: [String: ClassDef] = [:]

    /// Registered enum definitions keyed by type name. Populated by
    /// `enum Foo { … }` declarations.
    var enumDefs: [String: EnumDef] = [:]

    /// Extensions on built-in types (`Int`, `Double`, `String`, `Bool`,
    /// `Array`, …). Methods/properties/static members declared inside an
    /// `extension Int { … }` block live here, since builtins don't have a
    /// `StructDef` of their own. Extensions on user structs/enums are
    /// merged directly into the respective StructDef/EnumDef.
    var extensions: [String: ExtensionMembers] = [:]

    /// Flat bridge table — see `Bridge`. New bridge code writes here;
    /// runtime dispatch sites consult this before falling through to
    /// `extensions[…]`. The two will live side-by-side until the
    /// migration is complete.
    var _bridges: [String: Bridge] = [:]

    /// Cache for `bridgedTypeNames` — invalidated by `bridges` setter.
    var _bridgedTypeNamesCache: (count: Int, types: Set<String>)?

    /// Index of generic-constrained bridges: keyed by `"Type.member"`,
    /// each entry is a list of (parsed signature, bridge body) pairs
    /// — multiple overloads share a bucket. Built lazily on first
    /// access from the keys of `bridges` that mention `<...>`.
    var _genericIndex: [String: [(Signature, Bridge)]]?

    /// Index of property-shaped bridges: getter, optional setter, and
    /// the declared property-type spelling. Keyed by `"Type.member"`.
    var _propertyIndex: [String: PropertyEntry]?

    /// `typealias Foo = Bar` declarations. Looked up at type-resolution
    /// sites (coerce, struct/enum init dispatch, isTypeName, …).
    var typeAliases: [String: TypeSyntax] = [:]

    /// Names declared via `protocol P { … }`. Tracked solely so the type
    /// validator accepts `[P]` / `var x: P` annotations — conformance and
    /// witness checks aren't enforced (we dispatch dynamically by runtime
    /// value).
    var declaredProtocols: Set<String> = []

    /// Names of `BuiltinModule`s that have been registered, to make
    /// `register(module:)` idempotent.
    var registeredModules: Set<String> = []

    /// Script-side `CommandLine.arguments`. Three ways for a host to
    /// supply this, checked in order at the start of each ``eval(_:fileName:)``:
    ///
    /// 1. **Explicit** — set this property directly. Useful for tests
    ///    or embedders that want to override host argv. Index 0 is the
    ///    script path / `<expression>` sentinel; indices 1+ are the
    ///    user-supplied positional arguments.
    /// 2. **From the bound shell** — leave this empty and bind a
    ///    `ShellKit.Shell` whose `scriptName` + `positionalParameters`
    ///    describe the script's argv. SwiftBash's shebang dispatch
    ///    sets these on the subshell it constructs for the script,
    ///    so `CommandLine.arguments[0]` becomes the script path
    ///    automatically.
    /// 3. **Process default** — neither of the above. Falls through to
    ///    `Shell.processDefault`, which mirrors `ProcessInfo.processInfo
    ///    .arguments`. That's the standalone-CLI path.
    public var scriptArguments: [String] = []

    /// Modules whose import name (`Foundation`, `Darwin`, …) has appeared
    /// in an `import` statement at the top of a script. Foundation-side
    /// builtins gate their availability on this set so unimported uses
    /// fail with `cannot find '…' in scope`, matching `swiftc`.
    var importedModules: Set<String> = []

    /// Modules awaiting an `import <name>` statement before they're
    /// actually registered. Populated by `registerOnImport(...)` at
    /// startup. Multiple modules can share an import name (e.g. both
    /// `FoundationModule` and `CalendarModule` activate on
    /// `import Foundation`), so the value is a list.
    var pendingModules: [String: [BuiltinModule]] = [:]

    /// Generic-parameter names visible during type validation. Pushed
    /// when entering a `func<T, U>` / `struct Foo<T>`; popped on exit.
    /// Keeps `cannot find type 'T' in scope` diagnostics from firing on
    /// declarations like `func max<T: Comparable>(_ a: T, _ b: T)`.
    var genericTypeParameters: [Set<String>] = []

    /// Type names whose static-member surface is implicitly visible — like
    /// `Self` inside a `static func` body. Pushed when entering a static
    /// method or static getter, popped on exit. Identifier lookups consult
    /// this before reporting `cannot find 'X' in scope`, and assignments
    /// route through it so `total += 1` writes back into `staticMembers`.
    var staticContextStack: [String] = []

    /// Class names whose member surface is the current `self`-context for
    /// dispatch resolution. Pushed when entering an init / method body of
    /// a class. `super.method(...)` and `super.init(...)` consult this to
    /// find the parent class.
    var currentClassContextStack: [String] = []

    /// Class instances currently being initialized. Property writes that
    /// land on these instances skip their `willSet`/`didSet` observers —
    /// matching Swift's rule that observers don't fire from inside the
    /// owning class's initializer.
    var instancesInInit: Set<ObjectIdentifier> = []

    /// Comparison helpers for opaque values, keyed by their boxed type
    /// name (e.g. `"Date"`). Returns `< 0` / `0` / `> 0` like `Comparable`'s
    /// natural ordering. Registered via `registerComparator(on:compare:)`.
    /// `applyBinary` consults this when both operands are `.opaque` with
    /// matching type names, so script code can write `dateA < dateB`.
    var opaqueComparators: [String: (Value, Value) throws -> Int] = [:]

    /// Attached-attribute names the host has declared it understands
    /// (`registerAttribute("Test")`). The unsupported-attribute
    /// preflight skips these, and declarations carrying one are
    /// recorded in `attributedDeclarations`.
    var registeredAttributes: Set<String> = []

    /// Declarations observed carrying a registered attribute, in
    /// execution order. Enumerated by `declarations(withAttribute:)`;
    /// re-executing a declaration replaces its earlier entry.
    var attributedDeclarations: [AttributedDeclaration] = []

    /// The most recently parsed source file and its file name, retained
    /// after `eval(...)` returns so runtime errors can be rendered with
    /// source-listing context (`renderRuntimeError`).
    var currentSourceFile: SourceFileSyntax?
    var currentFileName: String?

    /// UTF-8 offset of the innermost expression currently being
    /// evaluated. Task-local rather than instance state so concurrent
    /// script tasks (`Task { … }` in script code) each see their own
    /// evaluation position, and so the value unwinds automatically —
    /// no save/restore discipline that an interleaved `await` could
    /// corrupt. Bound by the expression dispatcher around every node;
    /// read at the bridge/builtin boundary to attach source positions
    /// to errors (issue #15) and surfaced to host-registered builtins
    /// as ``currentCallOffset`` (issue #16).
    @TaskLocal static var evaluationOffset: Int?

    /// Source offset (UTF-8) of the call currently being evaluated, if
    /// any — issue #16. Valid for the duration of a builtin or bridge
    /// invocation: while a closure registered via
    /// ``registerGlobal(name:body:)`` (or any bridge body) runs, this
    /// is the offset of the call expression that invoked it. A host
    /// that *records* a failure instead of throwing (Swift Testing /
    /// XCTest-style assertions) captures this alongside the issue and
    /// later renders it with ``renderSourceContext(at:message:)``.
    ///
    /// Outside evaluation this is `nil`. The value is task-scoped, not
    /// interpreter-scoped: with nested interpreters it reflects the one
    /// currently evaluating on this task.
    public var currentCallOffset: Int? { Interpreter.evaluationOffset }

    /// Construct an interpreter.
    ///
    /// Without arguments, output and error route through
    /// ``ShellKit/Shell/current`` so the same code does the right
    /// thing both standalone and under an embedder. Tests that need
    /// to capture override `output:` / `error:` directly.
    ///
    /// **Output contract.** Both closures receive the **verbatim**
    /// bytes the script emitted, including any trailing newline
    /// `print(_:terminator:)` chose to add. (This is a deliberate
    /// change from earlier SwiftScript versions, where `output`
    /// took a newline-less line and the closure was expected to add
    /// the terminator — a contract that prevented routing
    /// `print(x, terminator: "")` correctly.)
    public init(
        output: @escaping (String) -> Void = { ShellKit.Shell.current.stdout($0) },
        error: @escaping (String) -> Void = { ShellKit.Shell.current.stderr($0) }
    ) {
        self.rootScope = Scope()
        self.output = output
        self.error = error
        registerBuiltins()
    }

    /// Parse and execute `source` asynchronously. Every step of evaluation
    /// is async so that script `await` calls into bridged async builtins
    /// (URLSession, file I/O, …) actually suspend and resume rather than
    /// being faked. Returns the value of the last top-level expression,
    /// or `.void` if there were no expressions.
    @discardableResult
    public func eval(_ source: String, fileName: String = "<input>") async throws -> Value {
        // Refresh `CommandLine.arguments` from whichever of
        // {scriptArguments, Shell.current.scriptName +
        // positionalParameters, Shell.processDefault} is populated.
        // Done on every eval so a single Interpreter instance can run
        // multiple scripts with different argv (rare, but the
        // alternative — relying on the host to register the bridge by
        // hand — is the leakage that motivated this whole refactor).
        bindCommandLineArguments()

        let result = ScriptParser.parse(source, fileName: fileName)
        currentSourceFile = result.sourceFile
        currentFileName = fileName
        if result.hasErrors {
            throw ParseError(
                diagnostics: result.errors,
                formatted: result.formattedDiagnostics()
            )
        }
        // Boundary check before any execution: declarations carrying
        // attributes we'd silently ignore (`@propertyWrapper`,
        // `@resultBuilder`, custom wrappers/macros) are refused whole
        // — running them would produce plausible values that disagree
        // with stock Swift.
        try rejectUnsupportedAttributes(in: result.sourceFile)
        var last: Value = .void
        for item in result.sourceFile.statements {
            last = try await execute(item: item, in: rootScope)
        }
        return last
    }

    /// Like ``eval(_:fileName:)`` but tailored for whole-script
    /// execution: catches ``ScriptExit`` thrown by `exit(_:)` /
    /// `abort()` and converts it into the returned ``ShellKit/ExitStatus``.
    /// Anything else (parse error, runtime error) propagates.
    ///
    /// Hosts that want to honor `exit(N)` from script use this in
    /// place of `eval`; existing callers that consume the last-
    /// expression value keep using `eval` and handle `ScriptExit`
    /// themselves if they care.
    public func evalScript(
        _ source: String,
        fileName: String = "<input>"
    ) async throws -> ExitStatus {
        do {
            _ = try await eval(source, fileName: fileName)
            return .success
        } catch let exit as ScriptExit {
            return exit.status
        }
    }

    /// Resolve the script's `CommandLine.arguments` from the layered
    /// sources documented on ``scriptArguments`` and register the
    /// resulting array as a static-value bridge. Called from
    /// ``eval(_:fileName:)`` immediately before parsing.
    private func bindCommandLineArguments() {
        let argv: [String]
        if !scriptArguments.isEmpty {
            argv = scriptArguments
        } else {
            // Pull from the active `ShellKit.Shell`. `scriptName` ends
            // up as argv[0]; positional parameters fill 1+. Fallback
            // to an empty argv only if both are empty (the very-edge
            // case where an embedder built a Shell from scratch
            // without arguments).
            let shell = ShellKit.Shell.current
            var assembled = [shell.scriptName]
            assembled.append(contentsOf: shell.positionalParameters)
            argv = assembled.first == "" && assembled.count == 1 ? [] : assembled
        }
        bridges["static let CommandLine.arguments"] =
            .staticValue(.array(argv.map { .string($0) }))
    }
}

/// Bag of members added to a built-in type via `extension Int { … }` etc.
public struct ExtensionMembers {
    public var methods: [String: Function] = [:]
    public var computedProperties: [String: Function] = [:]
    public var staticMembers: [String: Value] = [:]
    /// Type-call initializers, keyed by the argument-label list. `URL(string:)`
    /// stores under `["string"]`; `Date()` under `[]`. Unlabeled arguments
    /// use `"_"` per the symbol-graph convention.
    public var initializers: [[String]: Function] = [:]
}

/// User-defined struct: stored properties (in declaration order), methods,
/// and computed properties (stored as zero-arg getter Functions).
public struct StructDef {
    public let name: String
    public let properties: [Property]
    public var methods: [String: Function] = [:]
    public var computedProperties: [String: Function] = [:]
    /// Custom initializers. When non-empty, the auto-generated memberwise
    /// init is suppressed (matching Swift's rule). A call site picks an
    /// init by matching argument labels.
    public var customInits: [Function] = []
    /// Static members keyed by name. Static let/var stores a value; static
    /// func stores a `.function` value; static var with `{ body }` is
    /// evaluated once at type-declaration time and stored as a value.
    public var staticMembers: [String: Value] = [:]
    /// `subscript(dynamicMember name: String) -> T` — when set, a
    /// member access that misses the normal lookup falls through to
    /// this subscript with the member name as a String. Mirrors
    /// `@dynamicMemberLookup` on the host side.
    public var dynamicMemberSubscript: Function?

    public struct Property {
        public let name: String
        public let type: TypeSyntax?
        /// Default value expression for stored properties declared with
        /// `var x: T = expr`. Evaluated at memberwise-init time when the
        /// caller omits the corresponding argument.
        public let defaultValue: ExprSyntax?
    }
}

/// User-defined class. Same shape as `StructDef` plus an optional
/// `superclass` name (the class this one inherits from). Method/property
/// dispatch walks the chain; `super.…` accesses the parent's surface
/// directly. We don't model `final`, `open`, or visibility — every member
/// is reachable from anywhere.
public struct ClassDef {
    public let name: String
    public let superclass: String?
    /// Name of a bridged Foundation/stdlib type that this class wraps.
    /// Set when the inheritance clause names a type registered in
    /// `extensions` (e.g. `Date`, `URL`) — script code can't truly
    /// inherit from those, but we model it as composition: instances
    /// hold a real Foundation value as `bridgedBase` and member lookup
    /// falls through to the bridged extension surface for anything the
    /// script doesn't override.
    public let bridgedParent: String?
    public var properties: [StructDef.Property]
    public var methods: [String: Function] = [:]
    public var computedProperties: [String: Function] = [:]
    public var customInits: [Function] = []
    public var staticMembers: [String: Value] = [:]
    /// `willSet`/`didSet` observers keyed by stored-property name. Each
    /// observer is a function that takes `newValue` (for willSet) or
    /// `oldValue` (for didSet) — invoked around every write to that
    /// property, including inside `init`.
    public var willSetObservers: [String: Function] = [:]
    public var didSetObservers: [String: Function] = [:]
    /// Argument-label lists for `required init(...)`s declared on this
    /// class. Subclasses with their own custom inits must explicitly
    /// provide each required init their ancestors declare; the validator
    /// emits the matching swiftc diagnostic when one is missing.
    public var requiredInitSignatures: [[String?]] = []
    /// `subscript(dynamicMember name: String) -> T` — fallback for
    /// `@dynamicMemberLookup`-style classes. Resolved after explicit
    /// fields, computed properties, and methods all miss.
    public var dynamicMemberSubscript: Function?
}

/// Mutable reference cell for a class instance. Holding the same
/// `ClassInstance` from two `Value`s gives reference semantics — writes
/// through one observer surface to the other.
public final class ClassInstance {
    public let typeName: String
    public var fields: [StructField]
    /// Underlying Foundation/stdlib value when this class wraps a
    /// bridged type (the `ClassDef.bridgedParent` mechanism). Holds the
    /// raw payload that `.opaque(bridgedParent, payload)` would carry —
    /// member access on the wrapper falls through here.
    public var bridgedBase: Any?
    public init(typeName: String, fields: [StructField], bridgedBase: Any? = nil) {
        self.typeName = typeName
        self.fields = fields
        self.bridgedBase = bridgedBase
    }
}

/// User-defined enum: cases (with optional associated types and raw
/// values), methods, and a possible declared raw type ("Int", "String").
public struct EnumDef {
    public let name: String
    public let cases: [Case]
    public let rawType: String?
    public var methods: [String: Function] = [:]
    public var staticMembers: [String: Value] = [:]

    public struct Case {
        public let name: String
        /// Number of associated values (each can be of any type at runtime).
        public let arity: Int
        /// Raw value, present only on raw-value enums.
        public let rawValue: Value?
    }
}

public struct ParseError: Error, CustomStringConvertible {
    public let diagnostics: [Diagnostic]
    /// Multi-line `swiftc`-style rendering with source-line context and
    /// caret pointers; print this to stderr verbatim.
    public let formatted: String

    public var description: String { formatted }
}

/// Helpers used across the dispatch files. Also referenced by bridge code
/// generated by `BridgeGeneratorTool` — the unbox helpers below are part
/// of the bridge ABI.
func toDouble(_ value: Value) throws -> Double {
    switch value {
    case .int(let i):    return Double(i)
    case .double(let d): return d
    default:
        throw RuntimeError.invalid("expected numeric value, got \(typeName(value))")
    }
}

func unboxInt(_ value: Value) throws -> Int {
    if case .int(let v) = value { return v }
    throw RuntimeError.invalid("expected Int, got \(typeName(value))")
}

func unboxString(_ value: Value) throws -> String {
    if case .string(let v) = value { return v }
    throw RuntimeError.invalid("expected String, got \(typeName(value))")
}

func unboxBool(_ value: Value) throws -> Bool {
    if case .bool(let v) = value { return v }
    throw RuntimeError.invalid("expected Bool, got \(typeName(value))")
}

/// Wrap a host-Swift value of type `T` (a Foundation type, an NSObject,
/// etc.) as a `Value.opaque`. The `typeName` should match the spelling
/// used by the bridge generator's type table (e.g. `"CharacterSet"`).
func boxOpaque<T>(_ value: T, typeName: String) -> Value {
    return .opaque(typeName: typeName, value: value)
}

// MARK: Fixed-width integer / Float unboxers
//
// Scripts model every integer as `.int` and every floating value as
// `.double`; the narrow-width Foundation parameter types (`Int32`
// seek offsets, `UInt8` bytes, `Float` fractions) convert here with
// range checks so an out-of-range script value fails loudly instead
// of truncating.

func toFixedWidth<T: FixedWidthInteger>(_ value: Value, as _: T.Type) throws -> T {
    let i = try unboxInt(value)
    guard let narrowed = T(exactly: i) else {
        throw RuntimeError.invalid("value \(i) out of range for \(T.self)")
    }
    return narrowed
}

func toInt8(_ v: Value) throws -> Int8 { try toFixedWidth(v, as: Int8.self) }
func toInt16(_ v: Value) throws -> Int16 { try toFixedWidth(v, as: Int16.self) }
func toInt32(_ v: Value) throws -> Int32 { try toFixedWidth(v, as: Int32.self) }
func toInt64(_ v: Value) throws -> Int64 { try toFixedWidth(v, as: Int64.self) }
func toUInt8(_ v: Value) throws -> UInt8 { try toFixedWidth(v, as: UInt8.self) }
func toUInt16(_ v: Value) throws -> UInt16 { try toFixedWidth(v, as: UInt16.self) }
func toUInt32(_ v: Value) throws -> UInt32 { try toFixedWidth(v, as: UInt32.self) }
func toUInt64(_ v: Value) throws -> UInt64 { try toFixedWidth(v, as: UInt64.self) }
func toUInt(_ v: Value) throws -> UInt { try toFixedWidth(v, as: UInt.self) }
func toFloat(_ v: Value) throws -> Float { Float(try toDouble(v)) }

/// Box an unsigned host value that may exceed `Int.max` — throws
/// instead of silently wrapping.
func boxUnsignedAsInt<T: FixedWidthInteger>(_ value: T) throws -> Value {
    guard let i = Int(exactly: value) else {
        throw RuntimeError.invalid("value \(value) exceeds Int.max")
    }
    return .int(i)
}

// MARK: Collection / Optional unboxers (bridge ABI)

/// Elements of a script `.array`, for element-wise unboxing in
/// generated collection-parameter bridges.
func unboxArray(_ value: Value) throws -> [Value] {
    if case .array(let xs) = value { return xs }
    throw RuntimeError.invalid("expected Array, got \(typeName(value))")
}

/// Entries of a script `.dict` as `(key, value)` pairs.
func unboxDict(_ value: Value) throws -> [(key: Value, value: Value)] {
    if case .dict(let entries) = value {
        return entries.map { ($0.key, $0.value) }
    }
    throw RuntimeError.invalid("expected Dictionary, got \(typeName(value))")
}

/// Elements of a script `.set`.
func unboxSet(_ value: Value) throws -> [Value] {
    if case .set(let xs) = value { return xs }
    throw RuntimeError.invalid("expected Set, got \(typeName(value))")
}

/// Unwrap one `Optional` layer for an optional-typed parameter:
/// `.optional(x)` yields `x`, `.optional(nil)` yields `nil`, and a
/// bare value passes through as `.some` (scripts hand non-optional
/// values to `T?` slots all the time).
func unboxOptionalValue(_ value: Value) throws -> Value? {
    if case .optional(let inner) = value { return inner }
    return value
}

/// Property-setter tolerance for Foundation's implicitly-unwrapped
/// members: `formatter.timeZone = TimeZone(identifier: "UTC")`
/// assigns a failable-init Optional to an IUO slot in stock Swift.
/// Wrapped values unwrap; `.optional(nil)` passes through so an
/// optional-typed setter still receives nil (and a non-optional one
/// still throws in its unboxer).
func unwrapForSetter(_ value: Value) -> Value {
    if case .optional(let inner?) = value { return unwrapForSetter(inner) }
    return value
}

/// Recover a host-Swift value from a `Value.opaque`. Verifies the boxed
/// `typeName` matches the requested type — a type-name mismatch throws
/// a runtime error rather than risking a bad downcast.
func unboxOpaque<T>(_ value: Value, as: T.Type, typeName expectedName: String) throws -> T {
    guard case .opaque(let actualName, let any) = value else {
        throw RuntimeError.invalid("expected \(expectedName), got \(typeName(value))")
    }
    guard actualName == expectedName else {
        throw RuntimeError.invalid("expected \(expectedName), got \(actualName)")
    }
    guard let cast = any as? T else {
        throw RuntimeError.invalid("opaque value of type \(actualName) failed to cast")
    }
    return cast
}
