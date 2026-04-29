import Foundation

/// Single-table bridge to Foundation/stdlib surfaces. Each entry is one
/// declaration the script can reach — a method, a computed property, a
/// static value, an initializer. Dispatch is one dictionary lookup
/// keyed by a Swift-style declaration:
///
///     "func String.uppercased()"               — instance method, no args
///     "func String.split(separator:)"          — instance method, one labeled arg
///     "var URL.absoluteString"                 — instance computed
///     "init String(reflecting:)"               — initializer
///     "static let Int.max"                     — static value
///     "static func Int.random(in:)"            — static method
///
/// The descriptor reads exactly like a Swift declaration, which makes the
/// table greppable from outside the codebase and lets the kind be
/// recognised at a glance instead of decoded from punctuation.
public enum Bridge {
    /// Instance method. Receives the value the method was called on
    /// plus the positional arguments.
    case method((Value, [Value]) async throws -> Value)
    /// Read-only computed property — getter only.
    case computed((Value) async throws -> Value)
    /// Property setter — paired with a `.computed` entry that shares
    /// the same `Type.member` suffix but is keyed `set var Type.member`.
    /// Receives the receiver value and the new value; mutates the
    /// underlying reference in place. Emitted for `var` properties on
    /// auto-bridged classes; struct-typed mutable properties are out
    /// of scope (they'd need writeback through the opaque payload).
    case setter((Value, Value) async throws -> Void)
    /// Initializer reachable via `Type(label1:label2:)`.
    case `init`(([Value]) async throws -> Value)
    /// Static value (`static let`). The value is fixed at registration
    /// time.
    case staticValue(Value)
    /// Static method (`Int.random(in:)`, `URL.init`-shaped factories
    /// reached through a static slot). Wrapped into a `.function`
    /// value at lookup time so call sites see it as a callable.
    case staticMethod(([Value]) async throws -> Value)
}

/// Indexed view of a property bridge — getter (always present for
/// readable properties) and setter (present for `var` properties on
/// bridged classes), plus the declared property-type spelling so the
/// runtime can resolve implicit-member access in assignment RHS.
public struct PropertyEntry {
    public var typeSpelling: String      // `"JSONEncoder.OutputFormatting"` or empty
    public var getter: Bridge?
    public var setter: Bridge?
    public init(typeSpelling: String) {
        self.typeSpelling = typeSpelling
    }
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
            _genericIndex = nil
            _propertyIndex = nil
        }
    }

    /// Lazy index of generic-constrained bridges grouped by
    /// `"Type.method"`. Built from the subset of `bridges` keys whose
    /// declaration contains a generic clause (`<...>`). Rebuilt
    /// whenever `bridges` is reassigned. Invalid keys are dropped
    /// silently — they'd surface as missing bridges at call time.
    var genericMethodCandidates: [String: [(Signature, Bridge)]] {
        if let cached = _genericIndex { return cached }
        var index: [String: [(Signature, Bridge)]] = [:]
        for (key, bridge) in _bridges {
            // Only entries with generic clauses; cheap pre-filter.
            guard key.contains("<") else { continue }
            guard let sig = try? Signature.parse(key) else { continue }
            guard sig.isGeneric, let member = sig.memberName else { continue }
            let bucket = "\(sig.receiver).\(member)"
            index[bucket, default: []].append((sig, bridge))
        }
        _genericIndex = index
        return index
    }

    /// Lazy index of property-shaped bridges keyed by `"Type.member"`.
    /// Each entry pairs the bridge body (getter or setter) with the
    /// declared property type spelling (`"JSONEncoder.OutputFormatting"`).
    /// Built from `bridges` keys that begin with `"var "` or
    /// `"set var "`; rebuilt whenever `bridges` is reassigned.
    var propertyIndex: [String: PropertyEntry] {
        if let cached = _propertyIndex { return cached }
        var index: [String: PropertyEntry] = [:]
        for (key, bridge) in _bridges {
            let stripped: Substring
            let isSetter: Bool
            if key.hasPrefix("var ") {
                stripped = key.dropFirst("var ".count); isSetter = false
            } else if key.hasPrefix("set var ") {
                stripped = key.dropFirst("set var ".count); isSetter = true
            } else {
                continue
            }
            // `Type.member: ReturnType` — split on `:`. Older keys
            // without the type still resolve to a getter-only entry
            // with empty type spelling.
            let qualName: String
            let typeSpelling: String
            if let colon = stripped.firstIndex(of: ":") {
                qualName = String(stripped[..<colon]).trimmingCharacters(in: .whitespaces)
                typeSpelling = String(stripped[stripped.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                qualName = String(stripped).trimmingCharacters(in: .whitespaces)
                typeSpelling = ""
            }
            var entry = index[qualName] ?? PropertyEntry(typeSpelling: typeSpelling)
            if isSetter { entry.setter = bridge } else { entry.getter = bridge }
            if !typeSpelling.isEmpty { entry.typeSpelling = typeSpelling }
            index[qualName] = entry
        }
        _propertyIndex = index
        return index
    }

    /// Set of type names that appear as the type prefix of any bridge
    /// key — e.g. registering `"var URLSession.shared"` makes
    /// `"URLSession"` a known type for `isTypeName`. Nested types are
    /// registered too: `"static let JSONEncoder.OutputFormatting.prettyPrinted"`
    /// contributes both `"JSONEncoder"` and
    /// `"JSONEncoder.OutputFormatting"` so nested-type member access
    /// can resolve. Cached and rebuilt when `bridges` is reassigned.
    /// Subscript writes go through the setter above, which clears the
    /// cache too.
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
    /// `names`. Strips the leading kind keyword (`func`, `var`, `init`,
    /// `static let`, `static func`) and any trailing `(...)` label
    /// list, then walks the dotted type area inserting each prefix.
    private func insertTypePrefixes(of key: String, into names: inout Set<String>) {
        let body = stripKindKeyword(key)
        // Init keys are `Type(labels)` with no member name — the type
        // area is everything before `(`. Other kinds are `Type.member`
        // (or `Type.Nested.member`); strip the last `.member` segment.
        let typeArea: Substring
        if let paren = body.firstIndex(of: "(") {
            // Could be init `Type(...)` or method `Type.method(...)`.
            // For methods, the type area is up to the last dot before
            // the paren. For init, the whole prefix is the type.
            let head = body[..<paren]
            if let lastDot = head.lastIndex(of: ".") {
                typeArea = head[..<lastDot]
            } else {
                typeArea = head
            }
        } else if let lastDot = body.lastIndex(of: ".") {
            typeArea = body[..<lastDot]
        } else {
            return
        }
        guard !typeArea.isEmpty else { return }
        var current = ""
        for seg in typeArea.split(separator: ".") {
            current = current.isEmpty ? String(seg) : current + "." + seg
            names.insert(current)
        }
    }

    /// Drop the leading kind keyword from a bridge key, returning the
    /// remainder (`Type.member` / `Type(labels)` shape).
    private func stripKindKeyword(_ key: String) -> Substring {
        for prefix in ["set var ", "static let ", "static func ", "func ", "var ", "init "] {
            if key.hasPrefix(prefix) {
                return key.dropFirst(prefix.count)
            }
        }
        return Substring(key)
    }

    /// True if `typeName` names an auto-bridged Foundation class (the
    /// generator's class allowlist surfaced through `bridges`). Used by
    /// the assignment dispatcher to allow `let foo = JSONEncoder()` /
    /// `foo.outputFormatting = …` — the `let` only freezes the reference,
    /// not the pointee, same as it does for script-side `class` types.
    /// Detection is signature-shaped: a property setter exists for at
    /// least one `var Type.member`. Avoids needing a separate registry
    /// of "which types are class-shaped".
    func isAutoBridgedClass(_ typeName: String) -> Bool {
        let prefix = "\(typeName)."
        for entry in propertyIndex {
            guard entry.key.hasPrefix(prefix), entry.value.setter != nil else { continue }
            return true
        }
        return false
    }
}

extension Interpreter {
    // MARK: - Key formatting helpers
    //
    // Each bridge key is prefixed with the Swift declaration kind so
    // method/computed/init/static slots can coexist on the same
    // dictionary. Helpers below are the single source of truth for the
    // key shape — dispatch sites and registration sites both go
    // through them.

    /// `func Type.method(label1:label2:)`
    func bridgeKey(forMethod methodName: String, on typeName: String, labels: [String?]) -> String {
        let labelText = labels.map { ($0 ?? "_") + ":" }.joined()
        return "func \(typeName).\(methodName)(\(labelText))"
    }

    /// `init Type(label1:label2:)`
    func bridgeKey(forInit typeName: String, labels: [String?]) -> String {
        let labelText = labels.map { ($0 ?? "_") + ":" }.joined()
        return "init \(typeName)(\(labelText))"
    }

    /// `var Type.property`
    func bridgeKey(forComputedProperty propName: String, on typeName: String) -> String {
        "var \(typeName).\(propName)"
    }

    /// `static let Type.property`
    func bridgeKey(forStaticValue propName: String, on typeName: String) -> String {
        "static let \(typeName).\(propName)"
    }

    /// `static func Type.method(label1:label2:)`
    func bridgeKey(forStaticMethod methodName: String, on typeName: String, labels: [String?]) -> String {
        let labelText = labels.map { ($0 ?? "_") + ":" }.joined()
        return "static func \(typeName).\(methodName)(\(labelText))"
    }
}
