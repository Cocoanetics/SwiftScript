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
    /// Static value. `static let` properties are pre-evaluated; the
    /// closure is fixed at registration time.
    case staticValue(Value)
    /// Static method (`Int.random(in:)`, `URL.init`-shaped factories
    /// reached through a static slot). Wrapped into a `.function`
    /// value at lookup time so call sites see it as a callable.
    case staticMethod(([Value]) async throws -> Value)
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
    /// known type for `isTypeName`. Nested types are registered too:
    /// `"JSONEncoder.OutputFormatting.prettyPrinted"` contributes both
    /// `"JSONEncoder"` and `"JSONEncoder.OutputFormatting"` so nested-
    /// type member access can resolve. Cached and rebuilt when
    /// `bridges` is reassigned. Subscript writes
    /// (`bridges["X"] = .method(…)`) go through the setter above,
    /// which clears the cache too.
    var bridgedTypeNames: Set<String> {
        if let cached = _bridgedTypeNamesCache, cached.count == _bridges.count {
            return cached.types
        }
        var names = Set<String>()
        for key in _bridges.keys {
            insertTypePrefixes(of: key, into: &names)
        }
        _bridgedTypeNamesCache = (count: _bridges.count, types: names)
        return names
    }

    /// Walk a bridge key and add every dot-separated type prefix to
    /// `names`. The last segment is always a member (`prettyPrinted`,
    /// or for inits, the parenthesised label list `(string:)`); the
    /// preceding segments form one or more candidate type names.
    /// Static-member keys carry a `.Type.` discriminator before the
    /// member; we drop that segment from the type prefix so the
    /// metatype isn't accidentally surfaced as a real type name.
    private func insertTypePrefixes(of key: String, into names: inout Set<String>) {
        // Strip the trailing `(...)` label list if present — that's the
        // init form. What's left is dotted: type segments only.
        let typeArea: Substring
        if let paren = key.firstIndex(of: "(") {
            typeArea = key[..<paren]
        } else if let lastDot = key.lastIndex(of: ".") {
            typeArea = key[..<lastDot]
        } else {
            // Bare bridge key like "globalFn" — no type to register.
            return
        }
        guard !typeArea.isEmpty else { return }
        // Insert every dot-prefix of the type area: "A.B.C" contributes
        // "A", "A.B", "A.B.C". Skip a trailing "Type" segment — that's
        // the static-member discriminator, not a real nested type.
        var current = ""
        let segments = typeArea.split(separator: ".")
        for (i, seg) in segments.enumerated() {
            if seg == "Type" && i == segments.count - 1 { continue }
            current = current.isEmpty ? String(seg) : current + "." + seg
            names.insert(current)
        }
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
