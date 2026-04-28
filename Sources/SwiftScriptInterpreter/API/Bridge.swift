import Foundation

/// Single-table bridge to Foundation/stdlib surfaces. Each entry is one
/// declaration the script can reach — a method, a computed property, a
/// static value, an initializer. Dispatch is one dictionary lookup
/// keyed by a Swift-style descriptor:
///
///     "String.uppercased()"                — instance method, no args
///     "String.split(separator:)"           — instance method, one labeled
///     "String(reflecting:)"                — initializer
///     "Int.max"                            — static value or computed
///     "Date.timeIntervalSinceNow"          — computed property
///     "URL.absoluteString"                 — computed property
///
/// The descriptor mirrors how Swift names symbols in error messages and
/// DocC, which makes the table greppable from outside the codebase.
///
/// Static methods are stored as `.staticValue(.function(fn))` — same
/// shape Swift sees: `Int.random(in:)` is a value-of-function-type
/// reached through a static slot.
public enum Bridge {
    /// Instance method. Receives the value the method was called on
    /// plus the positional arguments.
    case method((Value, [Value]) async throws -> Value)
    /// Read-only computed property — getter only. Setter-shaped
    /// properties stay in the per-def storage path (where mutating
    /// writeback already lives).
    case computed((Value) async throws -> Value)
    /// Initializer reachable via `Type(label1:label2:)`.
    case `init`(([Value]) async throws -> Value)
    /// Static value. For `static let` properties the closure is
    /// pre-evaluated; for static methods we store a `.function(fn)`
    /// that the call site invokes.
    case staticValue(Value)
}

extension Interpreter {
    /// Flat dispatch table for bridged surfaces — see `Bridge`.
    /// Hand-written modules and generated files both write into this
    /// dict; runtime dispatch sites consult it before falling through
    /// to the per-def storage used for user-declared types.
    public var bridges: [String: Bridge] {
        get { _bridges }
        set {
            _bridges = newValue
            _bridgedTypeNamesCache = nil
        }
    }

    /// Set of type names that appear as the prefix of any bridge key —
    /// e.g. registering `"URLSession.shared"` makes `"URLSession"` a
    /// known type for `isTypeName`. Cached and rebuilt when `bridges`
    /// is reassigned. Subscript writes (`bridges["X"] = .method(…)`)
    /// go through the setter above, which clears the cache too.
    var bridgedTypeNames: Set<String> {
        if let cached = _bridgedTypeNamesCache, cached.count == _bridges.count {
            return cached.types
        }
        var names = Set<String>()
        for key in _bridges.keys {
            names.insert(typeNamePrefix(of: key))
        }
        _bridgedTypeNamesCache = (count: _bridges.count, types: names)
        return names
    }

    /// Type-name prefix of a bridge key — everything up to the first
    /// `.` (member separator) or `(` (init label list).
    private func typeNamePrefix(of key: String) -> String {
        var end = key.endIndex
        if let dot = key.firstIndex(of: ".") { end = dot }
        if let paren = key.firstIndex(of: "("), paren < end { end = paren }
        return String(key[..<end])
    }
}

extension Interpreter {
    // MARK: - Key formatting helpers

    /// Build the descriptor for an instance method dispatched by name
    /// + ordered label list. `nil` labels become `_` (the unlabelled
    /// position marker Swift uses for `func foo(_:)`).
    func bridgeKey(forMethod methodName: String, on typeName: String, labels: [String?]) -> String {
        let labelText = labels.map { ($0 ?? "_") + ":" }.joined()
        return "\(typeName).\(methodName)(\(labelText))"
    }

    /// Build the descriptor for an initializer's label list — same
    /// shape as method keys but without the dot.
    func bridgeKey(forInit typeName: String, labels: [String?]) -> String {
        let labelText = labels.map { ($0 ?? "_") + ":" }.joined()
        return "\(typeName)(\(labelText))"
    }

    /// Build the descriptor for a property / static-value access.
    func bridgeKey(forProperty propName: String, on typeName: String) -> String {
        "\(typeName).\(propName)"
    }
}
