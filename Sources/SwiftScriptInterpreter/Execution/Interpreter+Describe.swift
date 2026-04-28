import SwiftSyntax

extension Interpreter {
    /// Render `value` to a display string. Honors a script-defined
    /// `description: String` computed property when the value is a
    /// struct / class / enum that has one, mirroring Swift's
    /// `CustomStringConvertible` lookup. Falls back to `Value.description`
    /// otherwise.
    ///
    /// Used by `print(_:)` and string interpolation (`"\(value)"`) so
    /// custom `description` implementations in script behave the way
    /// Swift code expects without needing a separate hook.
    func describe(_ value: Value) async throws -> String {
        switch value {
        case .structValue(let typeName, let fields):
            if let getter = structDefs[typeName]?.computedProperties["description"] {
                let (result, _) = try await invokeStructMethod(
                    getter, on: value, fields: fields, args: []
                )
                if case .string(let s) = result { return s }
            }
            // Recurse into field values so nested customizations render
            // correctly without needing a separate `elementDescription`.
            let parts = try await fields.asyncMap {
                "\($0.name): \(try await describeElement($0.value))"
            }
            return "\(typeName)(\(parts.joined(separator: ", ")))"
        case .classInstance(let inst):
            if let def = classDefs[inst.typeName],
               let getter = lookupClassComputed(on: def, "description")
            {
                let r = try await invokeClassMethod(getter, on: inst, def: def, args: [])
                if case .string(let s) = r { return s }
            }
            return inst.typeName
        case .enumValue(let typeName, _, _):
            if let getter = enumDefs[typeName]?.methods["description"],
               getter.parameters.isEmpty
            {
                let r = try await invokeBuiltinExtensionMethod(
                    getter, on: value, args: []
                )
                if case .string(let s) = r { return s }
            }
            return value.description
        case .array(let xs):
            // Arrays render their elements via the same describe path
            // so a `[Person]` prints with each element's custom
            // description rather than the default field dump.
            let parts = try await xs.asyncMap { try await describeElement($0) }
            return "[" + parts.joined(separator: ", ") + "]"
        case .dict(let entries):
            if entries.isEmpty { return "[:]" }
            let parts = try await entries.asyncMap {
                "\(try await describeElement($0.key)): \(try await describeElement($0.value))"
            }
            return "[" + parts.joined(separator: ", ") + "]"
        case .set(let xs):
            let parts = try await xs.asyncMap { try await describeElement($0) }
            return "Set([" + parts.sorted().joined(separator: ", ") + "])"
        case .optional(let inner):
            if let inner { return "Optional(\(try await describeElement(inner)))" }
            return "nil"
        case .tuple(let elements, let labels):
            let useLabels = !labels.isEmpty
                && labels.count == elements.count
                && labels.allSatisfy { $0 != nil }
            let parts: [String]
            if useLabels {
                parts = try await zip(labels, elements).asyncMap {
                    "\($0.0!): \(try await describeElement($0.1))"
                }
            } else {
                parts = try await elements.asyncMap {
                    try await describeElement($0)
                }
            }
            return "(" + parts.joined(separator: ", ") + ")"
        default:
            return value.description
        }
    }

    /// Variant of `describe` for elements inside a collection / tuple —
    /// matches the `elementDescription` shape (strings get quoted) so
    /// `print([1, "x"])` reads as `[1, "x"]`.
    private func describeElement(_ value: Value) async throws -> String {
        if case .string(let s) = value { return "\"\(s)\"" }
        return try await describe(value)
    }

    /// `CustomDebugStringConvertible` lookup. Returns the type's
    /// `debugDescription` getter result if defined, otherwise falls
    /// through to the regular `describe` path. Used by `dump(_:)` and
    /// `String(reflecting:)`.
    func debugDescribe(_ value: Value) async throws -> String {
        switch value {
        case .structValue(let typeName, let fields):
            if let getter = structDefs[typeName]?.computedProperties["debugDescription"] {
                let (result, _) = try await invokeStructMethod(
                    getter, on: value, fields: fields, args: []
                )
                if case .string(let s) = result { return s }
            }
        case .classInstance(let inst):
            if let def = classDefs[inst.typeName],
               let getter = lookupClassComputed(on: def, "debugDescription")
            {
                let r = try await invokeClassMethod(getter, on: inst, def: def, args: [])
                if case .string(let s) = r { return s }
            }
        case .enumValue(let typeName, _, _):
            if let getter = enumDefs[typeName]?.methods["debugDescription"],
               getter.parameters.isEmpty
            {
                let r = try await invokeBuiltinExtensionMethod(
                    getter, on: value, args: []
                )
                if case .string(let s) = r { return s }
            }
        default: break
        }
        return try await describe(value)
    }
}
