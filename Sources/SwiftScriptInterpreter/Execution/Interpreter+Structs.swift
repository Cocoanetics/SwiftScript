import SwiftSyntax

extension Interpreter {
    /// Register a `struct Foo { … }` declaration. Stored properties become
    /// memberwise-init parameters; methods become callable on instances with
    /// `self` (and each property name) bound in the call scope.
    func execute(structDecl: StructDeclSyntax, in scope: Scope) async throws -> Value {
        let name = structDecl.name.text
        // Push generic parameters into the validator scope, mirroring
        // what we do in `funcDecl`.
        let structGenerics = structDecl.genericParameterClause?.parameters
            .map { $0.name.text }
            .reduce(into: Set<String>()) { $0.insert($1) } ?? []
        if !structGenerics.isEmpty {
            genericTypeParameters.append(structGenerics)
        }
        defer {
            if !structGenerics.isEmpty { genericTypeParameters.removeLast() }
        }
        var properties: [StructDef.Property] = []
        var methods: [String: Function] = [:]
        var computed: [String: Function] = [:]
        var customInits: [Function] = []
        // Static members are resolved in two passes: first we collect them
        // (so struct-name references in their initializers can resolve
        // later), then after registering the struct shell we evaluate each.
        var pendingStaticInits: [(name: String, expr: ExprSyntax)] = []
        var pendingStaticGetters: [(name: String, fn: Function)] = []
        var staticMethods: [String: Function] = [:]

        for member in structDecl.memberBlock.members {
            let decl = member.decl
            if let varDecl = decl.as(VariableDeclSyntax.self) {
                let isStatic = varDecl.modifiers.contains { mod in
                    mod.name.tokenKind == .keyword(.static)
                }
                for binding in varDecl.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                        throw RuntimeError.unsupported(
                            "non-identifier struct property pattern",
                            at: binding.positionAfterSkippingLeadingTrivia.utf8Offset
                        )
                    }
                    let propName = ident.identifier.text
                    if isStatic {
                        if let accessorBlock = binding.accessorBlock {
                            // `static var x: T { body }` — invoke once at
                            // declaration time, store the result.
                            let body = try extractGetterBody(accessorBlock)
                            let fn = Function(
                                name: "\(name).\(propName)",
                                parameters: [],
                                returnType: binding.typeAnnotation?.type,
                                staticContext: name,
                                kind: .user(body: body, capturedScope: scope)
                            )
                            pendingStaticGetters.append((propName, fn))
                        } else if let initializer = binding.initializer {
                            pendingStaticInits.append((propName, initializer.value))
                        }
                        // static var without init or body: skip (uncommon).
                        continue
                    }
                    // Instance properties.
                    if let accessorBlock = binding.accessorBlock {
                        let body = try extractGetterBody(accessorBlock)
                        computed[propName] = Function(
                            name: "\(name).\(propName)",
                            parameters: [],
                            returnType: binding.typeAnnotation?.type,
                            isMutating: false,
                            kind: .user(body: body, capturedScope: scope)
                        )
                    } else {
                        if let propType = binding.typeAnnotation?.type {
                            try validateType(propType)
                        }
                        properties.append(StructDef.Property(
                            name: propName,
                            type: binding.typeAnnotation?.type,
                            defaultValue: binding.initializer?.value
                        ))
                    }
                }
            } else if let initDecl = decl.as(InitializerDeclSyntax.self) {
                guard let body = initDecl.body else { continue }
                let params = initDecl.signature.parameterClause.parameters.map { p -> Function.Parameter in
                    let firstName = p.firstName.text
                    let label = (firstName == "_") ? nil : firstName
                    let internalName = (p.secondName?.text) ?? firstName
                    return Function.Parameter(label: label, name: internalName, type: p.type)
                }
                customInits.append(Function(
                    name: "\(name).init",
                    parameters: params,
                    returnType: nil,
                    isMutating: false,
                    kind: .user(body: body.statements, capturedScope: scope)
                ))
            } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
                let methodName = funcDecl.name.text
                guard let body = funcDecl.body else { continue }
                let params = funcDecl.signature.parameterClause.parameters.map { p -> Function.Parameter in
                    let firstName = p.firstName.text
                    let label = (firstName == "_") ? nil : firstName
                    let internalName = (p.secondName?.text) ?? firstName
                    return Function.Parameter(label: label, name: internalName, type: p.type)
                }
                let isStatic = funcDecl.modifiers.contains { mod in
                    mod.name.tokenKind == .keyword(.static)
                }
                let isMutating = funcDecl.modifiers.contains { mod in
                    mod.name.tokenKind == .keyword(.mutating)
                }
                let fn = Function(
                    name: "\(name).\(methodName)",
                    parameters: params,
                    returnType: funcDecl.signature.returnClause?.type,
                    isMutating: isMutating,
                    staticContext: isStatic ? name : nil,
                    kind: .user(body: body.statements, capturedScope: scope)
                )
                if isStatic {
                    staticMethods[methodName] = fn
                } else {
                    methods[methodName] = fn
                }
            }
            // init / subscript / computed properties: not yet supported.
        }

        // Register the shell so static initializers that reference the
        // type itself (`static let zero = V(...)`) can resolve it.
        structDefs[name] = StructDef(
            name: name,
            properties: properties,
            methods: methods,
            computedProperties: computed,
            customInits: customInits,
            staticMembers: [:]
        )

        // Evaluate static initializers and getters; install everything.
        for (memberName, expr) in pendingStaticInits {
            let value = try await evaluate(expr, in: scope)
            structDefs[name]!.staticMembers[memberName] = value
        }
        for (memberName, getter) in pendingStaticGetters {
            let value = try await invoke(getter, args: [])
            structDefs[name]!.staticMembers[memberName] = value
        }
        for (memberName, fn) in staticMethods {
            structDefs[name]!.staticMembers[memberName] = .function(fn)
        }
        return .void
    }

    /// Pull the getter body from an `AccessorBlockSyntax`. Supports the
    /// implicit `{ expr }` form and the explicit `{ get { … } }` form.
    /// Other accessor kinds (set/willSet/didSet) aren't supported yet.
    func extractGetterBody(_ accessorBlock: AccessorBlockSyntax) throws -> CodeBlockItemListSyntax {
        switch accessorBlock.accessors {
        case .getter(let items):
            return items
        case .accessors(let accessors):
            for accessor in accessors {
                if accessor.accessorSpecifier.tokenKind == .keyword(.get),
                   let body = accessor.body
                {
                    return body.statements
                }
            }
            throw RuntimeError.unsupported(
                "computed property without a `get` accessor",
                at: accessorBlock.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
    }

    /// Build a struct instance from an init call. If the struct declared
    /// custom inits, picks the one matching the call's argument labels;
    /// otherwise falls back to the auto-generated memberwise init.
    func instantiateStruct(
        _ def: StructDef,
        call: FunctionCallExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        if !def.customInits.isEmpty {
            let argSyntaxes = Array(call.arguments)
            let callLabels = argSyntaxes.map { $0.label?.text }
            // First match by arity + labels.
            for fn in def.customInits {
                guard fn.parameters.count == callLabels.count else { continue }
                let paramLabels = fn.parameters.map { $0.label }
                if zip(paramLabels, callLabels).allSatisfy({ $0 == $1 }) {
                    return try await invokeCustomInit(fn, def: def, call: call, in: scope)
                }
            }
            // No matching label set. If we have a single same-arity
            // candidate, produce Swift's specific label-mismatch message
            // ("extraneous argument label 'X:' in call" / "missing argument
            // label 'X:' in call"). Otherwise the generic overload error.
            if let single = def.customInits.first(where: { $0.parameters.count == callLabels.count }) {
                for (i, paramLabel) in single.parameters.map(\.label).enumerated() {
                    let callLabel = callLabels[i]
                    if paramLabel != callLabel {
                        if let cl = callLabel, paramLabel == nil {
                            throw RuntimeError.invalid(
                                "extraneous argument label '\(cl):' in call"
                            )
                        }
                        if let pl = paramLabel, callLabel == nil {
                            throw RuntimeError.invalid(
                                "missing argument label '\(pl):' in call"
                            )
                        }
                        if let cl = callLabel, let pl = paramLabel {
                            throw RuntimeError.invalid(
                                "incorrect argument label in call (have '\(cl):', expected '\(pl):')"
                            )
                        }
                    }
                }
            }
            throw RuntimeError.invalid(
                "no exact matches in call to initializer for '\(def.name)'"
            )
        }

        // Auto-generated memberwise init. Properties at the end with
        // declared default values may be omitted by the caller (matching
        // Swift's behavior for trailing defaults).
        let argSyntaxes = Array(call.arguments)
        guard argSyntaxes.count <= def.properties.count else {
            throw RuntimeError.invalid("extra argument in call")
        }
        // Properties not supplied by the caller must have a default.
        for i in argSyntaxes.count..<def.properties.count {
            if def.properties[i].defaultValue == nil {
                throw RuntimeError.invalid(
                    "missing argument for parameter '\(def.properties[i].name)' in call"
                )
            }
        }

        var fields: [StructField] = []
        for (i, prop) in def.properties.enumerated() {
            if i < argSyntaxes.count {
                let argSyntax = argSyntaxes[i]
                let actualLabel = argSyntax.label?.text
                if actualLabel != prop.name {
                    throw RuntimeError.invalid(
                        "incorrect argument label in call (have '\(actualLabel ?? "_"):', expected '\(prop.name):')"
                    )
                }
                // Pass `expecting:` so implicit-member access (`.three`)
                // resolves against the property's declared type.
                var value = try await evaluate(
                    argSyntax.expression,
                    expecting: prop.type,
                    in: scope
                )
                if let propType = prop.type {
                    value = try await coerce(
                        value: value,
                        expr: argSyntax.expression,
                        toType: propType,
                        in: .argument
                    )
                }
                fields.append(StructField(name: prop.name, value: value))
            } else {
                // Trailing default.
                let value = try await evaluate(prop.defaultValue!, in: scope)
                fields.append(StructField(name: prop.name, value: value))
            }
        }
        return .structValue(typeName: def.name, fields: fields)
    }

    /// Run a custom init. We pre-seed `self` with `.void` placeholders for
    /// each stored property so `self.x = …` writes inside the body land
    /// somewhere; we don't enforce "all properties must be initialized" —
    /// the user's body is trusted.
    private func invokeCustomInit(
        _ fn: Function,
        def: StructDef,
        call: FunctionCallExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("init must be a user-defined function")
        }
        // Coerce args against parameter types. Pass `expecting:` so
        // implicit-member access in arg positions resolves against the
        // declared param type.
        let argSyntaxes = Array(call.arguments)
        var args: [Value] = []
        for (i, argSyntax) in argSyntaxes.enumerated() {
            let paramType = (i < fn.parameters.count) ? fn.parameters[i].type : nil
            var value = try await evaluate(
                argSyntax.expression, expecting: paramType, in: scope
            )
            if let paramType {
                value = try await coerce(
                    value: value,
                    expr: argSyntax.expression,
                    toType: paramType,
                    in: .argument
                )
            }
            args.append(value)
        }

        // Pre-seed self.
        let initialFields = def.properties.map {
            StructField(name: $0.name, value: .void)
        }
        let blankSelf = Value.structValue(typeName: def.name, fields: initialFields)

        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: blankSelf, mutable: true)
        for (param, value) in zip(fn.parameters, args) {
            callScope.bind(param.name, value: value, mutable: false)
        }

        returnTypeStack.append(nil)
        defer { returnTypeStack.removeLast() }

        do {
            for item in body {
                _ = try await execute(item: item, in: callScope)
            }
        } catch is ReturnSignal {
            // Bare `return` inside an init is allowed; we don't return a value.
        }

        guard let final = callScope.lookup("self")?.value else {
            throw RuntimeError.invalid("init: 'self' lost from scope")
        }
        return final
    }

    /// Invoke a method on a struct instance. `self` is bound in the call
    /// scope (mutable for `mutating` methods, immutable otherwise). Bare
    /// property references resolve via the self-property fallback in
    /// `evaluate(DeclReferenceExpr…)` and the assignment paths.
    ///
    /// Returns both the function's return value and the (possibly mutated)
    /// final `self` so a `mutating` call site can write the new instance
    /// back to the source variable.
    func invokeStructMethod(
        _ fn: Function,
        on instance: Value,
        fields: [StructField],
        args: [Value]
    ) async throws -> (returnValue: Value, finalSelf: Value) {
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("struct method must be a user-defined function")
        }
        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: instance, mutable: fn.isMutating)

        guard args.count == fn.parameters.count else {
            if args.count > fn.parameters.count {
                throw RuntimeError.invalid("extra argument in call")
            }
            throw RuntimeError.invalid("missing argument for parameter #\(args.count + 1) in call")
        }
        for (param, value) in zip(fn.parameters, args) {
            callScope.bind(param.name, value: value, mutable: false)
        }

        returnTypeStack.append(fn.returnType)
        defer { returnTypeStack.removeLast() }

        let returnValue: Value
        var caught: Error? = nil
        do {
            var last: Value = .void
            for item in body {
                last = try await execute(item: item, in: callScope)
            }
            returnValue = last
        } catch let signal as ReturnSignal {
            returnValue = signal.value
        } catch {
            caught = error
            returnValue = .void
        }
        // Run any `defer` blocks the body registered. Mutations the
        // deferred bodies make to `self` need to land *before* we read
        // `finalSelf`, so the mutating-method writeback at the call
        // site sees the post-defer state.
        await runDeferred(in: callScope)
        if let caught { throw caught }

        let finalSelf = callScope.lookup("self")?.value ?? instance
        return (returnValue, finalSelf)
    }
}
