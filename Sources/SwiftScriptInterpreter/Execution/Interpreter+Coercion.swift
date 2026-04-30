import SwiftSyntax

/// Where a coercion is happening, used purely to phrase the error message
/// to match Swift's wording.
enum CoercionContext {
    case binding         // `let x: T = ...`
    case argument        // function call argument
    case returnValue     // `return ...` against a declared return type
}

/// Classify how an expression's literal-ness affects coercion.
/// - `.integerLiteral`: integer-literal expression (or arithmetic of
///   only integer literals). Adapts polymorphically to Int / Double /
///   any `ExpressibleByIntegerLiteral`.
/// - `.floatLiteral`: contains a Double literal somewhere. Adapts to
///   Double / any `ExpressibleByFloatLiteral`.
/// - `.stringLiteral`: bare string literal — `ExpressibleByStringLiteral`.
/// - `.booleanLiteral`: bare bool literal — `ExpressibleByBooleanLiteral`.
/// - `.nonLiteral`: depends on a variable or call result — its type is fixed.
enum LiteralKind {
    case integerLiteral
    case floatLiteral
    case stringLiteral
    case booleanLiteral
    case nonLiteral
}

/// Walk an expression syntactically to decide whether it can be coerced
/// between numeric types under Swift's literal-polymorphism rules.
func literalKind(_ expr: ExprSyntax) -> LiteralKind {
    if expr.is(IntegerLiteralExprSyntax.self) { return .integerLiteral }
    if expr.is(FloatLiteralExprSyntax.self)   { return .floatLiteral }
    if expr.is(StringLiteralExprSyntax.self)  { return .stringLiteral }
    if expr.is(BooleanLiteralExprSyntax.self) { return .booleanLiteral }
    if let infix = expr.as(InfixOperatorExprSyntax.self) {
        let l = literalKind(infix.leftOperand)
        let r = literalKind(infix.rightOperand)
        if l == .nonLiteral || r == .nonLiteral { return .nonLiteral }
        if l == .floatLiteral || r == .floatLiteral { return .floatLiteral }
        return .integerLiteral
    }
    if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
        return literalKind(prefix.expression)
    }
    if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1 {
        return literalKind(tuple.elements.first!.expression)
    }
    return .nonLiteral
}

extension Interpreter {
    /// Coerce `value` (produced by `expr`) to satisfy `type`. Throws the
    /// appropriate Swift-shaped error if no implicit coercion is possible.
    func coerce(
        value: Value,
        expr: ExprSyntax,
        toType rawType: TypeSyntax,
        in context: CoercionContext
    ) async throws -> Value {
        // Resolve `typealias` chains before doing anything else.
        let type = resolveType(rawType)
        // Type-existence is validated at DECL time (varDecl, funcDecl,
        // structDecl) — not here. By the time coerce runs, the type
        // has been seen and accepted in a context where its generic
        // parameters were in scope.
        // `T?` — wrap value as Optional, recursively coercing the inner.
        if let optionalType = type.as(OptionalTypeSyntax.self) {
            if case .optional = value {
                return value
            }
            let inner = try await coerce(value: value, expr: expr, toType: optionalType.wrappedType, in: context)
            return .optional(inner)
        }
        // `[Element]` array literal — coerce each element to the
        // declared element type. Mismatched elements get the swiftc-
        // style "cannot convert value of type 'X' to expected element
        // type 'Element'" diagnostic. Generic-parameter element types
        // (`[T]` inside a generic function) skip the check since we
        // can't verify the witness without runtime type tracking.
        if let arrayType = type.as(ArrayTypeSyntax.self),
           case .array(let elements) = value
        {
            let elementType = arrayType.element
            let elementSpelling = elementType.description.trimmingCharacters(in: .whitespaces)
            if isGenericPlaceholder(elementSpelling) {
                return value
            }
            // Source array-literal element exprs, used for per-element
            // literal-kind classification (so `[1, nil] as [Int?]`
            // promotes the `1` properly).
            let elementExprs: [ExprSyntax] = {
                if let arrExpr = expr.as(ArrayExprSyntax.self),
                   arrExpr.elements.count == elements.count
                {
                    return arrExpr.elements.map { $0.expression }
                }
                return Array(repeating: expr, count: elements.count)
            }()
            var coerced: [Value] = []
            coerced.reserveCapacity(elements.count)
            for (i, el) in elements.enumerated() {
                if valueMatchesType(el, elementType) {
                    coerced.append(el); continue
                }
                // Permit Int→Double literal coercion for arrays of
                // Double, mirroring Swift's literal-polymorphism.
                if elementSpelling == "Double", case .int(let n) = el {
                    coerced.append(.double(Double(n))); continue
                }
                // Subclass → superclass: a Dog is an Animal — slot
                // accepts the value unchanged.
                if case .classInstance(let inst) = el {
                    let chain = classDefChain(inst.typeName)
                    if chain.contains(where: { $0.name == elementSpelling }) {
                        coerced.append(el); continue
                    }
                }
                // Optional-promote: `[1, nil] as [Int?]` wraps non-
                // optional elements via the recursive coerce path.
                if elementType.as(OptionalTypeSyntax.self) != nil {
                    coerced.append(try await coerce(
                        value: el, expr: elementExprs[i],
                        toType: elementType, in: context
                    ))
                    continue
                }
                throw RuntimeError.invalid(
                    "cannot convert value of type '\(SwiftScriptInterpreter.typeName(el))' to expected element type '\(elementSpelling)'"
                )
            }
            return .array(coerced)
        }
        // `[Key: Value]` dict literal — coerce each entry's key and
        // value against the declared types. Mismatch fires the
        // "expected dictionary key type" / "expected dictionary value
        // type" diagnostic.
        if let dictType = type.as(DictionaryTypeSyntax.self),
           case .dict(let entries) = value
        {
            let keySpelling = dictType.key.description.trimmingCharacters(in: .whitespaces)
            let valueSpelling = dictType.value.description.trimmingCharacters(in: .whitespaces)
            var coerced: [DictEntry] = []
            for entry in entries {
                if !valueMatchesType(entry.key, dictType.key) {
                    throw RuntimeError.invalid(
                        "cannot convert value of type '\(SwiftScriptInterpreter.typeName(entry.key))' to expected dictionary key type '\(keySpelling)'"
                    )
                }
                if !valueMatchesType(entry.value, dictType.value) {
                    throw RuntimeError.invalid(
                        "cannot convert value of type '\(SwiftScriptInterpreter.typeName(entry.value))' to expected dictionary value type '\(valueSpelling)'"
                    )
                }
                coerced.append(entry)
            }
            return .dict(coerced)
        }
        // `Set<T>` literal — array literal coerced against a Set type.
        // Element-mismatch error mirrors the `Set<Int>.ArrayLiteralElement`
        // wording swiftc emits.
        if let identType = type.as(IdentifierTypeSyntax.self),
           identType.name.text == "Set",
           let element = identType.genericArgumentClause?.arguments.first.map({ TypeSyntax($0.argument) }),
           case .array(let elements) = value
        {
            let elementSpelling = element.description.trimmingCharacters(in: .whitespaces)
            var coerced: [Value] = []
            for el in elements {
                if !valueMatchesType(el, element) {
                    throw RuntimeError.invalid(
                        "cannot convert value of type '\(SwiftScriptInterpreter.typeName(el))' to expected element type 'Set<\(elementSpelling)>.ArrayLiteralElement' (aka '\(elementSpelling)')"
                    )
                }
                if !coerced.contains(el) { coerced.append(el) }
            }
            return .set(coerced)
        }

        // `(A, B, …)` tuple — coerce each element to its declared type.
        // Lets `let p: (Int?, Int?) = (5, nil)` promote `5` to `Optional`,
        // and matches Swift's element-wise coercion in tuple bindings.
        if let tupleType = type.as(TupleTypeSyntax.self),
           case .tuple(let elements, _) = value
        {
            let typeElements = Array(tupleType.elements)
            guard typeElements.count == elements.count else {
                throw RuntimeError.invalid(typeMismatchMessage(
                    from: SwiftScriptInterpreter.typeName(value),
                    to: type.description.trimmingCharacters(in: .whitespaces),
                    in: context
                ))
            }
            // If the source expr is itself a tuple literal, use its
            // sub-expressions for literal-kind classification; otherwise
            // fall back to the outer expr.
            let elementExprs: [ExprSyntax] = {
                if let tupleExpr = expr.as(TupleExprSyntax.self),
                   tupleExpr.elements.count == elements.count
                {
                    return tupleExpr.elements.map { $0.expression }
                }
                return Array(repeating: expr, count: elements.count)
            }()
            var coerced: [Value] = []
            for (i, el) in elements.enumerated() {
                let typeEl = typeElements[i]
                let elExpr = elementExprs[i]
                coerced.append(try await coerce(
                    value: el, expr: elExpr, toType: typeEl.type, in: context
                ))
            }
            // Pull the declared labels onto the coerced tuple so member
            // access by label works downstream (`mm.min`).
            let labels: [String?] = typeElements.map { typeEl in
                guard let firstName = typeEl.firstName else { return nil }
                return firstName.tokenKind == .wildcard ? nil : firstName.text
            }
            return .tuple(coerced, labels: labels)
        }
        // For non-identifier types (function types, …) we don't enforce —
        // the runtime will catch usage mismatches.
        guard let identType = type.as(IdentifierTypeSyntax.self) else {
            return value
        }
        let typeName = identType.name.text

        // Wrapper class flowing into a slot that expects its bridged
        // parent: hand over the underlying Foundation/stdlib payload as
        // an `.opaque` so host-side functions see the real value.
        if case .classInstance(let inst) = value,
           let parent = classDefs[inst.typeName]?.bridgedParent,
           parent == typeName,
           let base = inst.bridgedBase
        {
            return .opaque(typeName: parent, value: base)
        }

        // Expressible-by-literal hooks. When the source value is a
        // primitive that came from a literal expression and the target
        // is a script-defined type providing the matching
        // `init(integerLiteral:)` / `init(floatLiteral:)` /
        // `init(stringLiteral:)`, dispatch to it. Mirrors how Swift
        // synthesizes `ExpressibleBy*Literal` conformance.
        if let coerced = try await tryExpressibleByLiteral(
            value: value, expr: expr, targetType: typeName
        ) {
            return coerced
        }

        switch (typeName, value) {
        // Same-type passthrough.
        case ("Int",    .int):    return value
        case ("Double", .double): return value
        case ("String", .string): return value
        case ("Bool",   .bool):   return value
        case ("Void",   .void):   return value

        // Int → Double: only allowed for polymorphic integer-literal expressions.
        case ("Double", .int(let i)):
            if literalKind(expr) == .integerLiteral {
                return .double(Double(i))
            }
            throw RuntimeError.invalid(typeMismatchMessage(
                from: "Int", to: "Double", in: context
            ))

        // Double → Int: never implicit, even for literals.
        case ("Int", .double):
            throw RuntimeError.invalid(typeMismatchMessage(
                from: "Double", to: "Int", in: context
            ))

        default:
            // For known scalar types, an incompatible value is a real error.
            // Other targets (user struct types, generic identifiers) just
            // passthrough — the runtime will catch usage mismatches.
            if ["Int", "Double", "String", "Bool"].contains(typeName) {
                throw RuntimeError.invalid(typeMismatchMessage(
                    from: SwiftScriptInterpreter.typeName(value),
                    to: typeName,
                    in: context
                ))
            }
            return value
        }
    }
}

extension Interpreter {
    /// Walk a TypeSyntax recursively and throw `cannot find type 'X' in
    /// scope` for any nominal that isn't recognized. Generic parameters
    /// inside `[T]`, `[K: V]`, `Set<T>`, `T?`, `(A, B)`, function types
    /// are all validated. Unknown types in raw form (UnsafePointer<…>,
    /// type-eraser existentials, etc.) are silently passed through —
    /// the runtime would catch a real misuse later.
    func validateType(_ type: TypeSyntax) throws {
        if let optional = type.as(OptionalTypeSyntax.self) {
            try validateType(optional.wrappedType); return
        }
        if let implicit = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            try validateType(implicit.wrappedType); return
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            try validateType(array.element); return
        }
        if let dict = type.as(DictionaryTypeSyntax.self) {
            try validateType(dict.key); try validateType(dict.value); return
        }
        if let tuple = type.as(TupleTypeSyntax.self) {
            for el in tuple.elements { try validateType(el.type) }
            return
        }
        if let fn = type.as(FunctionTypeSyntax.self) {
            for el in fn.parameters { try validateType(el.type) }
            try validateType(fn.returnClause.type)
            return
        }
        if let ident = type.as(IdentifierTypeSyntax.self) {
            // Validate generic arguments first — `Set<Foo>` should
            // surface "cannot find type 'Foo'" before we worry about
            // whether `Set` itself is bridged.
            if let args = ident.genericArgumentClause {
                for arg in args.arguments {
                    try validateType(TypeSyntax(arg.argument))
                }
            }
            let name = ident.name.text
            if isKnownType(name) { return }
            throw RuntimeError.invalid("cannot find type '\(name)' in scope")
        }
        // Other type shapes (some existentials, member type refs, etc.)
        // are passed through — we don't model them.
    }

    /// Type-existence check. Wider than `isTypeName` since validation
    /// needs to recognize generic parameters and structural pseudo-
    /// types like `Void`/`Any`/`AnyObject`/`Character` that don't have
    /// a static-member surface but ARE valid type names.
    /// True if the given type name is a generic parameter currently in
    /// scope — used by the strict element-type checks to skip enforcement
    /// when the type is `T` and we don't know its witness.
    func isGenericPlaceholder(_ name: String) -> Bool {
        for frame in genericTypeParameters where frame.contains(name) {
            return true
        }
        return false
    }

    /// Try to synthesize an `ExpressibleBy*Literal` conversion from a
    /// primitive `value` to a script-defined `targetType`. Returns nil
    /// if the type doesn't define the matching literal init or if
    /// `value` isn't a literal-shaped primitive.
    func tryExpressibleByLiteral(
        value: Value, expr: ExprSyntax, targetType: String
    ) async throws -> Value? {
        // Each ExpressibleBy*Literal protocol pairs a primitive shape
        // with the init label that synthesized conformance produces.
        // We probe the target's customInits for an exact label match.
        let candidates: [(label: String, source: Value?)]
        switch value {
        case .int:
            candidates = [
                ("integerLiteral", value),
                ("floatLiteral",  .double(Double(intValue(value) ?? 0))),
            ]
        case .double:
            candidates = [("floatLiteral", value)]
        case .string:
            candidates = [
                ("stringLiteral", value),
                ("extendedGraphemeClusterLiteral", value),
                ("unicodeScalarLiteral", value),
            ]
        case .bool:
            candidates = [("booleanLiteral", value)]
        default:
            return nil
        }
        // Only synthesize the conversion when the source expression
        // really is a literal (or a literal-typed binding); otherwise
        // we'd silently coerce a runtime Int into MyType and surprise
        // the user. `literalKind` walks the expression and reports
        // `.nonLiteral` for variable references.
        guard literalKind(expr) != .nonLiteral else { return nil }

        // Look up customInits on struct or class.
        let inits: [Function]
        if let def = structDefs[targetType] {
            inits = def.customInits
        } else if let def = classDefs[targetType] {
            inits = def.customInits
        } else {
            return nil
        }
        for (label, src) in candidates {
            guard let src else { continue }
            if let initFn = inits.first(where: {
                $0.parameters.count == 1 && $0.parameters[0].label == label
            }) {
                if let def = structDefs[targetType] {
                    return try await invokeStructInitWithArg(
                        initFn, def: def, arg: src
                    )
                }
                if let def = classDefs[targetType] {
                    return try await invokeClassInitWithArg(
                        initFn, def: def, arg: src
                    )
                }
            }
        }
        return nil
    }

    private func intValue(_ v: Value) -> Int? {
        if case .int(let n) = v { return n }
        return nil
    }

    private func invokeStructInitWithArg(
        _ fn: Function, def: StructDef, arg: Value
    ) async throws -> Value {
        // Mirror the relevant parts of `invokeCustomInit` without
        // re-evaluating the call's argument syntax — we already have
        // a coerced value to pass.
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("init must be a user-defined function")
        }
        let blank = Value.structValue(
            typeName: def.name,
            fields: def.properties.map { StructField(name: $0.name, value: .void) }
        )
        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: blank, mutable: true)
        callScope.bind(fn.parameters[0].name, value: arg, mutable: false)
        var failed = false
        do {
            for item in body {
                _ = try await execute(item: item, in: callScope)
            }
        } catch let signal as ReturnSignal {
            if fn.isFailable, case .optional(.none) = signal.value {
                failed = true
            }
        }
        let final = callScope.lookup("self")?.value ?? blank
        if fn.isFailable {
            return failed ? .optional(nil) : .optional(final)
        }
        return final
    }

    private func invokeClassInitWithArg(
        _ fn: Function, def: ClassDef, arg: Value
    ) async throws -> Value {
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("init must be a user-defined function")
        }
        var fields: [StructField] = []
        for prop in storedPropertyChain(of: def) {
            var initial: Value = .void
            if let defaultExpr = prop.defaultValue {
                initial = try await evaluate(defaultExpr, in: capturedScope)
                if let pt = prop.type {
                    initial = try await coerce(
                        value: initial, expr: defaultExpr, toType: pt, in: .binding
                    )
                }
            }
            fields.append(StructField(name: prop.name, value: initial))
        }
        let inst = ClassInstance(typeName: def.name, fields: fields)
        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: .classInstance(inst), mutable: true)
        callScope.bind(fn.parameters[0].name, value: arg, mutable: false)
        currentClassContextStack.append(def.name)
        instancesInInit.insert(ObjectIdentifier(inst))
        defer {
            currentClassContextStack.removeLast()
            instancesInInit.remove(ObjectIdentifier(inst))
        }
        var failed = false
        do {
            for item in body {
                _ = try await execute(item: item, in: callScope)
            }
        } catch let signal as ReturnSignal {
            if fn.isFailable, case .optional(.none) = signal.value {
                failed = true
            }
        }
        if fn.isFailable {
            return failed ? .optional(nil) : .optional(.classInstance(inst))
        }
        return .classInstance(inst)
    }

    func isKnownType(_ name: String) -> Bool {
        if isTypeName(name) { return true }
        // Generic-parameter names introduced by an enclosing func/struct
        // decl. We don't enforce constraints, but the names need to
        // resolve as types when validating their use.
        for frame in genericTypeParameters where frame.contains(name) {
            return true
        }
        // User-declared protocols — tracked so `[P]` / `var x: P` validate.
        if declaredProtocols.contains(name) { return true }
        switch name {
        case "Set", "Dictionary", "ClosedRange",
             "Void", "Any", "AnyObject", "Never", "Character",
             "Substring",
             // Numeric stdlib types we accept as annotations even though
             // we don't model them with their own runtime case (Float
             // values flow as `.double`, the integer variants as `.int`).
             // The validator treats them as known so type-annotated
             // bindings don't fail on parse.
             "Float", "Float32", "Float64", "Float80",
             "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return true
        default:
            // Type aliases.
            if typeAliases[name] != nil { return true }
            return false
        }
    }
}

private func typeMismatchMessage(from: String, to: String, in context: CoercionContext) -> String {
    switch context {
    case .binding:
        return "cannot convert value of type '\(from)' to specified type '\(to)'"
    case .argument:
        return "cannot convert value of type '\(from)' to expected argument type '\(to)'"
    case .returnValue:
        return "cannot convert return expression of type '\(from)' to return type '\(to)'"
    }
}
