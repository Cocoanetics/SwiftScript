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
    /// Globals don't fit the `bridges` table (which keys on
    /// `Type.member` shapes); they bind directly into the root scope.
    public func registerGlobal(
        name: String,
        body: @escaping ([Value]) async throws -> Value
    ) {
        registerBuiltin(name: name, body: body)
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
}
