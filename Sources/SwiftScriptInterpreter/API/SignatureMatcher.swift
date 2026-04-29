import Foundation

/// Decision returned by the signature matcher.
public enum SignatureMatch {
    /// Call shape matches the signature; bindings holds resolved
    /// generic parameters (e.g. `["T": "MyStruct"]`).
    case match(bindings: [String: String])
    /// Doesn't match; reason is informational only.
    case noMatch(reason: String)
}

/// Predicate-style conformance check for a value against a protocol
/// name. Filled in by the interpreter at startup with the built-in
/// protocols; user-declared protocols are checked separately via the
/// per-type conformance machinery.
public typealias ProtocolPredicate = (Value) -> Bool

extension Interpreter {
    /// Built-in protocol predicates. The interpreter consults this
    /// table when a generic constraint references one of these names.
    /// Anything not in the table falls through to user-protocol
    /// conformance lookup.
    var builtinProtocolPredicates: [String: ProtocolPredicate] {
        [
            "Encodable":  { _ in true },          // ScriptCodable wraps any Value
            "Decodable":  { _ in true },          // (used with target metatype)
            "Codable":    { _ in true },
            "Hashable":   { _ in true },          // Value is dict-keyable
            "Equatable":  { _ in true },
            "Sendable":   { _ in true },          // not runtime-checkable
            "Comparable": { v in
                switch v {
                case .int, .double, .string: return true
                default: return false
                }
            },
            "BinaryInteger":      { v in if case .int = v { return true }; return false },
            "FixedWidthInteger":  { v in if case .int = v { return true }; return false },
            "BinaryFloatingPoint": { v in if case .double = v { return true }; return false },
            "Numeric": { v in
                switch v { case .int, .double: return true; default: return false }
            },
            "Sequence": { v in
                switch v {
                case .array, .set, .range, .string, .dict: return true
                default: return false
                }
            },
            "Collection": { v in
                switch v {
                case .array, .set, .range, .string, .dict: return true
                default: return false
                }
            },
            "StringProtocol": { v in if case .string = v { return true }; return false },
        ]
    }
}

/// Match a call shape against a parsed `Signature`. Walks param/arg
/// pairs in order, binding generics as it goes; checks each generic's
/// constraint via the predicate table; returns the resulting bindings
/// or a no-match reason.
///
/// The matcher is intentionally simple — it does NOT attempt full
/// overload ranking. Call sites are expected to filter to a small
/// candidate set first (via name + receiver) and pass each candidate
/// here; the first one that matches wins.
public func match(
    callArgs: [CallArgument],
    against sig: Signature,
    interpreter: Interpreter
) -> SignatureMatch {
    // Arity check.
    if callArgs.count != sig.parameters.count {
        return .noMatch(reason: "arity \(callArgs.count) vs \(sig.parameters.count)")
    }
    // Labels.
    for (i, arg) in callArgs.enumerated() {
        if arg.label != sig.parameters[i].label {
            return .noMatch(reason: "label mismatch at position \(i)")
        }
    }
    // Type check + generic binding.
    var bindings: [String: String] = [:]
    let genericNames = Set(sig.generics.map(\.name))
    for (i, arg) in callArgs.enumerated() {
        let paramType = sig.parameters[i].type
        // Generic placeholder appearing as `T` directly?
        if genericNames.contains(paramType) {
            // Bind T to the runtime type of the arg.
            let observedType = registryTypeName(arg.value)
            if let prior = bindings[paramType], prior != observedType {
                return .noMatch(reason: "generic \(paramType) bound twice: \(prior) vs \(observedType)")
            }
            bindings[paramType] = observedType
            continue
        }
        // `T.Type` metatype slot (decode-style)?
        if paramType.hasSuffix(".Type"),
           genericNames.contains(String(paramType.dropLast(".Type".count)))
        {
            // Expect a metatype value carrying the type name.
            guard case .opaque(typeName: "Metatype", let any) = arg.value,
                  let typeName = any as? String
            else {
                return .noMatch(reason: "expected metatype at position \(i)")
            }
            let varName = String(paramType.dropLast(".Type".count))
            bindings[varName] = typeName
            continue
        }
        // Concrete type — fall back to the simple equality check.
        if !concreteTypeMatches(arg.value, declaredType: paramType) {
            return .noMatch(reason: "type \(registryTypeName(arg.value)) ≠ \(paramType) at position \(i)")
        }
    }
    // Validate constraints on each generic var.
    for g in sig.generics {
        guard bindings[g.name] != nil else {
            // Generic not bound from any parameter — skipped (e.g.
            // appears only in return position). Constraints can't be
            // checked here; the bridge body will deal with it.
            continue
        }
        // Find the bound arg's value to test the predicate.
        guard let argIdx = sig.parameters.firstIndex(where: {
            $0.type == g.name || $0.type == g.name + ".Type"
        }) else { continue }
        let value = callArgs[argIdx].value
        for constraint in g.constraints {
            let predicate = interpreter.builtinProtocolPredicates[constraint]
                ?? { v in interpreter.userTypeConforms(v, to: constraint) }
            if !predicate(value) {
                return .noMatch(reason: "\(g.name) does not conform to \(constraint)")
            }
        }
    }
    return .match(bindings: bindings)
}

/// Concrete-type equality check used inside the matcher. Reuses the
/// same shape as `CallValidator.valueMatches` but takes the declared
/// type as a Swift-spelling string.
private func concreteTypeMatches(_ value: Value, declaredType decl: String) -> Bool {
    switch decl {
    case "Int":    if case .int = value { return true }
    case "Double":
        if case .double = value { return true }
        if case .int = value { return true }
    case "String": if case .string = value { return true }
    case "Bool":   if case .bool = value { return true }
    case "Any":    return true
    default:
        // Bracketed forms (`[Int]`, `[String: Int]`) — accept arrays/dicts.
        if decl.hasPrefix("["), decl.hasSuffix("]") {
            if decl.contains(":") { if case .dict = value { return true } }
            else { if case .array = value { return true } }
        }
        // Optional suffix.
        if decl.hasSuffix("?") {
            if case .optional(.none) = value { return true }
            let inner = String(decl.dropLast())
            if case .optional(.some(let v)) = value {
                return concreteTypeMatches(v, declaredType: inner)
            }
            return concreteTypeMatches(value, declaredType: inner)
        }
        // Opaque type by name.
        if case .opaque(let t, _) = value, t == decl { return true }
        // User-declared type by name.
        if registryTypeName(value) == decl { return true }
    }
    return false
}

extension Interpreter {
    /// Stub for user-declared protocol conformance lookup. The
    /// interpreter already tracks protocols and per-type conformance
    /// elsewhere; this helper centralises the check so the matcher
    /// doesn't have to know the storage layout.
    func userTypeConforms(_ value: Value, to protocolName: String) -> Bool {
        // For user-declared types, walk the def's conformance list.
        // For now, we accept any user type — the script-side `is`/`as?`
        // operators do the strict check. Tightening this is a follow-up.
        return true
    }

    /// Try generic-constrained method dispatch. Returns the bridge
    /// body's result if a candidate signature matches the call shape;
    /// `nil` if no candidate matches (caller falls through to
    /// non-generic dispatch).
    func tryGenericMethodDispatch(
        receiver: Value,
        methodName: String,
        args: [Value],
        labels: [String?]
    ) async throws -> Value? {
        let recvTypeName = registryTypeName(receiver)
        let bucket = "\(recvTypeName).\(methodName)"
        guard let candidates = genericMethodCandidates[bucket] else { return nil }
        let callArgs = zip(labels, args).map { CallArgument(label: $0, value: $1) }
        for (sig, bridge) in candidates {
            guard case .match = match(callArgs: callArgs, against: sig, interpreter: self)
            else { continue }
            switch bridge {
            case .method(let body):
                return try await body(receiver, args)
            default: continue
            }
        }
        return nil
    }
}
