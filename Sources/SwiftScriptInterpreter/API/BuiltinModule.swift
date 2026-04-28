import SwiftSyntax

/// A bundle of host-implemented functionality (math helpers, string ops,
/// I/O, …) that registers itself with an `Interpreter` at start-up. One
/// module per file, mirroring SwiftBash's one-command-per-file pattern.
public protocol BuiltinModule {
    /// Module identifier — used in diagnostics and to skip duplicates.
    var name: String { get }
    /// Add globals, instance methods, computed properties, and static
    /// members to `interpreter`.
    func register(into interpreter: Interpreter)
}

extension Interpreter {
    /// Install a module's contributions into this interpreter. Idempotent
    /// per module name — calling twice with the same module is a no-op.
    public func register(module m: BuiltinModule) {
        guard !registeredModules.contains(m.name) else { return }
        registeredModules.insert(m.name)
        m.register(into: self)
    }

    /// Defer a module's registration until a matching `import <name>`
    /// statement is processed. Used for Foundation-side builtins so they
    /// aren't available without the explicit import (matching `swiftc`).
    /// Multiple `importName`s can map to the same module — `Foundation`,
    /// `Darwin`, and `Glibc` all bring the C math globals.
    public func registerOnImport(_ importName: String, module m: BuiltinModule) {
        pendingModules[importName, default: []].append(m)
    }

    /// Called by the `ImportDeclSyntax` handler. Records the import and
    /// loads any pending modules wired to that name.
    func processImport(_ name: String) {
        importedModules.insert(name)
        if let modules = pendingModules.removeValue(forKey: name) {
            for m in modules { register(module: m) }
        }
    }

    /// True if any of the given module names has been imported. Special-
    /// case dispatch (FileManager, String(contentsOfFile:), …) consults
    /// this to decide whether the path should be active.
    public func isImported(any names: String...) -> Bool {
        for n in names where importedModules.contains(n) { return true }
        return false
    }

    // MARK: - Module registration helpers

    /// Register a top-level free function callable as `name(args…)`.
    public func registerGlobal(
        name: String,
        body: @escaping ([Value]) async throws -> Value
    ) {
        registerBuiltin(name: name, body: body)
    }

    /// Register an instance method on a built-in type. Inside `body`,
    /// `receiver` is the value the method was called on; `args` are the
    /// remaining positional arguments.
    public func registerMethod(
        on typeName: String,
        name: String,
        body: @escaping (_ receiver: Value, _ args: [Value]) async throws -> Value
    ) {
        var ext = extensions[typeName] ?? ExtensionMembers()
        ext.methods[name] = Function(
            name: "\(typeName).\(name)",
            parameters: [],
            kind: .builtinMethod(body)
        )
        extensions[typeName] = ext
    }

    /// Register a read-only computed property on a built-in type. The
    /// `get` closure receives the receiver value.
    public func registerComputed(
        on typeName: String,
        name: String,
        get body: @escaping (_ receiver: Value) async throws -> Value
    ) {
        var ext = extensions[typeName] ?? ExtensionMembers()
        ext.computedProperties[name] = Function(
            name: "\(typeName).\(name)",
            parameters: [],
            kind: .builtinMethod({ recv, _ in try await body(recv) })
        )
        extensions[typeName] = ext
    }

    /// Register a static value (`Int.max`-style) on a built-in type.
    public func registerStaticValue(
        on typeName: String,
        name: String,
        value: Value
    ) {
        var ext = extensions[typeName] ?? ExtensionMembers()
        ext.staticMembers[name] = value
        extensions[typeName] = ext
    }

    /// Register a static method (`Int.random(in:)`-style) on a built-in
    /// type. The receiver is implicit (the type itself).
    public func registerStaticMethod(
        on typeName: String,
        name: String,
        body: @escaping ([Value]) async throws -> Value
    ) {
        let fn = Function(
            name: "\(typeName).\(name)",
            parameters: [],
            kind: .builtin(body)
        )
        registerStaticValue(on: typeName, name: name, value: .function(fn))
    }

    /// Register a comparator for an opaque type so script code can write
    /// `a < b` / `a == b` etc. between two `.opaque(typeName: T)` values.
    /// The closure returns `< 0` / `0` / `> 0`, matching `Comparable`'s
    /// natural ordering. Throws if the boxed payloads don't match.
    public func registerComparator(
        on typeName: String,
        compare body: @escaping (Value, Value) throws -> Int
    ) {
        opaqueComparators[typeName] = body
    }

    /// Register a type-call initializer (`URL(string: "…")`, `Date()`).
    /// `labels` is the call-site argument label list — `"_"` for unlabelled
    /// positions. Multiple initializers can coexist on the same type as
    /// long as their label lists differ.
    public func registerInit(
        on typeName: String,
        labels: [String],
        body: @escaping ([Value]) async throws -> Value
    ) {
        var ext = extensions[typeName] ?? ExtensionMembers()
        let fn = Function(
            name: "\(typeName).init(\(labels.map { "\($0):" }.joined()))",
            parameters: [],
            kind: .builtin(body)
        )
        ext.initializers[labels] = fn
        extensions[typeName] = ext
    }
}
