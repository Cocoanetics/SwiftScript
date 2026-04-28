import SwiftSyntax

extension Interpreter {
    func evaluate(_ expr: ExprSyntax, in scope: Scope) async throws -> Value {
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            return try await evaluate(integerLiteral: intLit)
        }
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            return try await evaluate(floatLiteral: floatLit)
        }
        if let strLit = expr.as(StringLiteralExprSyntax.self) {
            return try await evaluate(stringLiteral: strLit, in: scope)
        }
        if let boolLit = expr.as(BooleanLiteralExprSyntax.self) {
            return .bool(boolLit.literal.tokenKind == .keyword(.true))
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return try await evaluate(infix: infix, in: scope)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            let op = prefix.operator.text
            let v = try await evaluate(prefix.expression, in: scope)
            return try await applyPrefix(op: op, value: v)
        }
        if let tuple = expr.as(TupleExprSyntax.self) {
            // `()` is Void; `(x)` is parens around a single expression;
            // `(a, b, …)` is a tuple value.
            if tuple.elements.isEmpty { return .void }
            if tuple.elements.count == 1, let only = tuple.elements.first {
                return try await evaluate(only.expression, in: scope)
            }
            let values = try await tuple.elements.asyncMap { try await evaluate($0.expression, in: scope) }
            // Capture syntactic labels (`(x: 1, y: 2)`) so member access
            // by label works without needing the receiver's declared type.
            let labels: [String?] = tuple.elements.map { $0.label?.text }
            return .tuple(values, labels: labels)
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            // Resolve precedence: a binding *inside* the method body
            // (parameters, locals) wins. An implicit-self field wins
            // over a captured outer var of the same name. Concretely:
            // walk both, then compare scopes — if the binding lives in
            // a scope between current and `self`'s scope (inclusive),
            // use it; otherwise prefer self.
            let nameOwner = scope.lookupWithOwner(name)
            let selfOwner = scope.lookupWithOwner("self")
            if let (selfBinding, selfScope) = selfOwner {
                let nameInsideMethod = nameOwner.map { selfScope.isAncestor(of: $0.1) } ?? false
                if !nameInsideMethod {
                    // Try implicit-self first.
                    if case .structValue(_, let fields) = selfBinding.value,
                       let f = fields.first(where: { $0.name == name })
                    {
                        return f.value
                    }
                    if case .classInstance(let inst) = selfBinding.value {
                        if let f = inst.fields.first(where: { $0.name == name }) {
                            return f.value
                        }
                        if let def = classDefs[inst.typeName],
                           let getter = lookupClassComputed(on: def, name)
                        {
                            return try await invokeClassMethod(getter, on: inst, def: def, args: [])
                        }
                    }
                }
            }
            if let binding = nameOwner?.0 {
                return binding.value
            }
            // Implicit-Self static member: bare `total` inside a static
            // method resolves to `Self.total` (the type's static member).
            if let staticOwner = staticContextStack.last {
                if let v = structDefs[staticOwner]?.staticMembers[name] {
                    return v
                }
                // Class static-context: walk inheritance chain.
                if classDefs[staticOwner] != nil {
                    for d in classDefChain(staticOwner) {
                        if let v = d.staticMembers[name] { return v }
                    }
                }
            }
            // Operator-as-function (`reduce(0, +)`, `sorted(by: >)`, …):
            // when an operator token appears in expression position and
            // isn't shadowed by a binding, hand back a Function wrapping it.
            if let opFn = operatorFunction(name) {
                return opFn
            }
            throw RuntimeError.unknownIdentifier(
                name,
                at: expr.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return try await evaluate(call: call, in: scope)
        }
        if let arrayExpr = expr.as(ArrayExprSyntax.self) {
            let elements = try await arrayExpr.elements.asyncMap { try await evaluate($0.expression, in: scope) }
            return .array(elements)
        }
        if let dictExpr = expr.as(DictionaryExprSyntax.self) {
            return try await evaluate(dictExpr: dictExpr, in: scope)
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return try await evaluate(memberAccess: memberAccess, in: scope)
        }
        if let subscriptCall = expr.as(SubscriptCallExprSyntax.self) {
            return try await evaluate(subscriptCall: subscriptCall, in: scope)
        }
        if expr.is(NilLiteralExprSyntax.self) {
            return .optional(nil)
        }
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            let v = try await evaluate(force.expression, in: scope)
            guard case .optional(let inner) = v else {
                throw RuntimeError.invalid(
                    "cannot force unwrap value of non-optional type '\(typeName(v))'"
                )
            }
            guard let unwrapped = inner else {
                throw RuntimeError.invalid("force-unwrapped a nil value")
            }
            return unwrapped
        }
        if let ifExpr = expr.as(IfExprSyntax.self) {
            return try await evaluate(ifExpr: ifExpr, in: scope)
        }
        if let switchExpr = expr.as(SwitchExprSyntax.self) {
            return try await evaluate(switchExpr: switchExpr, in: scope)
        }
        if let closure = expr.as(ClosureExprSyntax.self) {
            return try await evaluate(closure: closure, in: scope)
        }
        if let tryExpr = expr.as(TryExprSyntax.self) {
            return try await evaluate(try: tryExpr, in: scope)
        }
        // `await expr` — single-threaded interpreter has nothing to
        // suspend on, so `await` just unwraps to the inner expression.
        if let awaitExpr = expr.as(AwaitExprSyntax.self) {
            return try await evaluate(awaitExpr.expression, in: scope)
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            let cond = try await evaluate(ternary.condition, in: scope)
            guard case .bool(let b) = cond else {
                throw RuntimeError.invalid(
                    "ternary condition must be Bool, got \(typeName(cond))"
                )
            }
            return try await evaluate(b ? ternary.thenExpression : ternary.elseExpression, in: scope)
        }
        if let asExpr = expr.as(AsExprSyntax.self) {
            return try await evaluate(asExpr: asExpr, in: scope)
        }
        if let isExpr = expr.as(IsExprSyntax.self) {
            return try await evaluate(isExpr: isExpr, in: scope)
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            // Operator folding should have eliminated these. If we still see one,
            // it's a sign the input contained an operator we don't know about.
            throw RuntimeError.invalid(
                "unfolded operator sequence — unknown operator at offset \(seq.positionAfterSkippingLeadingTrivia.utf8Offset)"
            )
        }
        throw RuntimeError.unsupported(
            "expression \(expr.syntaxNodeType)",
            at: expr.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    private func evaluate(integerLiteral: IntegerLiteralExprSyntax) async throws -> Value {
        let raw = integerLiteral.literal.text.replacingOccurrences(of: "_", with: "")
        if let i = Int(raw) { return .int(i) }
        if raw.hasPrefix("0x"), let i = Int(raw.dropFirst(2), radix: 16) { return .int(i) }
        if raw.hasPrefix("0o"), let i = Int(raw.dropFirst(2), radix: 8)  { return .int(i) }
        if raw.hasPrefix("0b"), let i = Int(raw.dropFirst(2), radix: 2)  { return .int(i) }
        throw RuntimeError.invalid("could not parse integer literal '\(integerLiteral.literal.text)'")
    }

    private func evaluate(floatLiteral: FloatLiteralExprSyntax) async throws -> Value {
        let raw = floatLiteral.literal.text.replacingOccurrences(of: "_", with: "")
        guard let d = Double(raw) else {
            throw RuntimeError.invalid("could not parse float literal '\(floatLiteral.literal.text)'")
        }
        return .double(d)
    }

    private func evaluate(stringLiteral: StringLiteralExprSyntax, in scope: Scope) async throws -> Value {
        // `#"..."#` raw strings disable escape processing; honor that by
        // counting the leading `#` characters on the opening delimiter.
        let rawDelimiterCount = stringLiteral.openingPounds?.text.count ?? 0
        var result = ""
        for segment in stringLiteral.segments {
            if let strSeg = segment.as(StringSegmentSyntax.self) {
                if rawDelimiterCount > 0 {
                    result += strSeg.content.text
                } else {
                    result += unescapeStringSegment(strSeg.content.text)
                }
            } else if let exprSeg = segment.as(ExpressionSegmentSyntax.self) {
                for arg in exprSeg.expressions {
                    let v = try await evaluate(arg.expression, in: scope)
                    result += try await describe(v)
                }
            }
        }
        return .string(result)
    }
}

/// Process the standard Swift escape sequences inside a string segment.
/// Unknown escapes are passed through verbatim (matching the parser's
/// permissive behavior — bad escapes have already been flagged as
/// diagnostics by SwiftParser if relevant).
private func unescapeStringSegment(_ raw: String) -> String {
    var result = ""
    result.reserveCapacity(raw.count)
    var i = raw.startIndex
    while i < raw.endIndex {
        let c = raw[i]
        if c != "\\" {
            result.append(c)
            i = raw.index(after: i)
            continue
        }
        let next = raw.index(after: i)
        guard next < raw.endIndex else {
            result.append(c)
            i = next
            continue
        }
        let escape = raw[next]
        switch escape {
        case "n":  result.append("\n")
        case "t":  result.append("\t")
        case "r":  result.append("\r")
        case "0":  result.append("\0")
        case "\\": result.append("\\")
        case "\"": result.append("\"")
        case "'":  result.append("'")
        case "u":
            // \u{XXXX} — extract hex digits between braces.
            let openBrace = raw.index(after: next)
            guard openBrace < raw.endIndex, raw[openBrace] == "{" else {
                result.append(c); result.append(escape)
                i = raw.index(after: next)
                continue
            }
            var hex = ""
            var j = raw.index(after: openBrace)
            while j < raw.endIndex, raw[j] != "}" {
                hex.append(raw[j])
                j = raw.index(after: j)
            }
            if j < raw.endIndex,
               let scalarValue = UInt32(hex, radix: 16),
               let scalar = Unicode.Scalar(scalarValue)
            {
                result.append(Character(scalar))
                i = raw.index(after: j)
                continue
            }
            // Malformed \u — drop the marker, keep raw.
            result.append(c); result.append(escape)
            i = raw.index(after: next)
            continue
        default:
            result.append(c)
            result.append(escape)
        }
        i = raw.index(after: next)
    }
    return result
}

extension Interpreter {
    /// `value as T`, `value as? T`, `value as! T` — at runtime we test
    /// whether the value's `typeName` matches the target. The `?` form
    /// returns `Optional<T>` (`.optional(value)` on match, `.optional(nil)`
    /// otherwise). The `!` form throws a runtime error on mismatch.
    /// The bare `as` form is unconditional (compile-time-checked in real
    /// Swift); we honor it as `as!` since by the time we run, the cast
    /// is guaranteed correct or the program is malformed.
    func evaluate(asExpr: AsExprSyntax, in scope: Scope) async throws -> Value {
        let value = try await evaluate(asExpr.expression, in: scope)
        let mark = asExpr.questionOrExclamationMark?.text
        let matches = valueMatchesType(value, asExpr.type)
        switch mark {
        case "?":
            return matches ? .optional(value) : .optional(nil)
        case "!":
            if matches { return value }
            throw RuntimeError.invalid(
                "could not cast value of type '\(typeName(value))' to '\(asExpr.type.description.trimmingCharacters(in: .whitespaces))'"
            )
        default:
            // Bare `as` — bridge cast. swiftc has already checked it.
            return value
        }
    }

    /// `value is T` — runtime type check, returns Bool.
    func evaluate(isExpr: IsExprSyntax, in scope: Scope) async throws -> Value {
        let value = try await evaluate(isExpr.expression, in: scope)
        return .bool(valueMatchesType(value, isExpr.type))
    }

    /// True if `value`'s runtime type satisfies the target type spelling.
    /// Handles `Any` (always true), the four primitives, opaque-carried
    /// types (matched by `typeName`), user struct/enum types, and the
    /// generic-collection family.
    func valueMatchesType(_ value: Value, _ type: TypeSyntax) -> Bool {
        let raw = type.description.trimmingCharacters(in: .whitespaces)
        if raw == "Any" || raw == "AnyObject" { return true }
        // Duck-typed protocol existentials: we don't track conformances
        // statically, so any value passes a protocol-typed slot. Real
        // missing methods surface as a runtime error at the call site.
        if declaredProtocols.contains(raw) { return true }

        // Stdlib primitives by `Value` case.
        switch (raw, value) {
        case ("Int", .int):       return true
        case ("Double", .double): return true
        case ("String", .string): return true
        case ("Bool", .bool):     return true
        default: break
        }

        // Generic collections: `[T]`, `[K: V]`, `Set<T>`, `Range<T>`, etc.
        // We don't track element types, so any `.array` matches `[T]`,
        // any `.dict` matches `[K: V]`. This is laxer than swiftc but
        // matches our runtime model where collection element types are
        // dynamic.
        if raw.hasPrefix("[") && raw.contains(":") && !raw.contains("...") {
            if case .dict = value { return true }
        } else if raw.hasPrefix("[") && raw.hasSuffix("]") {
            if case .array = value { return true }
        }
        if raw.hasPrefix("Set<") {
            if case .set = value { return true }
        }
        if raw.hasPrefix("Range<") || raw.hasPrefix("ClosedRange<") {
            if case .range = value { return true }
        }
        if raw.hasPrefix("Optional<") || raw.hasSuffix("?") {
            if case .optional = value { return true }
        }

        // Opaque-carried types and user-defined structs/enums match by
        // `typeName`.
        let valueType = typeName(value)
        if valueType == raw { return true }

        // Class instances match against any ancestor class up the chain
        // (`Dog is Animal` → true, `Dog as? Mammal` → succeeds). For
        // wrapper classes, the bridged parent name also matches —
        // `myDate is Date` returns true.
        if case .classInstance(let inst) = value {
            for def in classDefChain(inst.typeName) {
                if def.name == raw { return true }
                if def.bridgedParent == raw { return true }
            }
        }

        return false
    }
}
