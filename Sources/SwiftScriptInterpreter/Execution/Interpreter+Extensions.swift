import SwiftSyntax

extension Interpreter {
    /// Register an `extension T { … }` block. Methods, computed properties,
    /// and static members get merged into the appropriate registry:
    ///   - StructDef.methods/etc. for `extension <user-struct>`
    ///   - EnumDef.methods/etc.   for `extension <user-enum>`
    ///   - `extensions[T]` bag    for `extension <Int|Double|...>`
    func execute(extensionDecl: ExtensionDeclSyntax, in scope: Scope) async throws -> Value {
        guard let identType = extensionDecl.extendedType.as(IdentifierTypeSyntax.self) else {
            throw RuntimeError.unsupported(
                "extension on non-identifier type",
                at: extensionDecl.extendedType.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        let typeName = identType.name.text
        let target = resolveExtensionTarget(typeName)
        guard target != .unknown else {
            throw RuntimeError.invalid("cannot extend unknown type '\(typeName)'")
        }

        for member in extensionDecl.memberBlock.members {
            let decl = member.decl
            if let funcDecl = decl.as(FunctionDeclSyntax.self) {
                guard let body = funcDecl.body else { continue }
                let methodName = funcDecl.name.text
                let params = funcDecl.signature.parameterClause.parameters.map { p -> Function.Parameter in
                    let firstName = p.firstName.text
                    let label = (firstName == "_") ? nil : firstName
                    let internalName = (p.secondName?.text) ?? firstName
                    return Function.Parameter(label: label, name: internalName, type: p.type)
                }
                let isStatic = funcDecl.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
                let isMutating = funcDecl.modifiers.contains { $0.name.tokenKind == .keyword(.mutating) }
                let fn = Function(
                    name: "\(typeName).\(methodName)",
                    parameters: params,
                    returnType: funcDecl.signature.returnClause?.type,
                    isMutating: isMutating,
                    kind: .user(body: body.statements, capturedScope: scope)
                )
                installMember(name: methodName, function: fn, isStatic: isStatic, target: target, typeName: typeName)
                continue
            }
            if let varDecl = decl.as(VariableDeclSyntax.self) {
                let isStatic = varDecl.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
                for binding in varDecl.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    let propName = ident.identifier.text
                    if let accessorBlock = binding.accessorBlock {
                        let body = try extractGetterBody(accessorBlock)
                        let getter = Function(
                            name: "\(typeName).\(propName)",
                            parameters: [],
                            returnType: binding.typeAnnotation?.type,
                            kind: .user(body: body, capturedScope: scope)
                        )
                        if isStatic {
                            // Evaluate once and store as a static value.
                            let value = try await invoke(getter, args: [])
                            installStaticValue(name: propName, value: value, target: target, typeName: typeName)
                        } else {
                            installComputed(name: propName, getter: getter, target: target, typeName: typeName)
                        }
                    } else if isStatic, let initializer = binding.initializer {
                        let value = try await evaluate(initializer.value, in: scope)
                        installStaticValue(name: propName, value: value, target: target, typeName: typeName)
                    }
                    // Stored instance properties on extensions aren't allowed in Swift; ignore.
                }
                continue
            }
        }

        return .void
    }

    private enum ExtensionTarget {
        case structType
        case enumType
        case builtin
        case unknown
    }

    private func resolveExtensionTarget(_ name: String) -> ExtensionTarget {
        if structDefs[name] != nil { return .structType }
        if enumDefs[name] != nil { return .enumType }
        switch name {
        case "Int", "Double", "String", "Bool", "Array", "Range", "Optional":
            return .builtin
        default: return .unknown
        }
    }

    private func installMember(
        name: String, function fn: Function,
        isStatic: Bool, target: ExtensionTarget, typeName: String
    ) {
        switch target {
        case .structType:
            if isStatic { structDefs[typeName]!.staticMembers[name] = .function(fn) }
            else        { structDefs[typeName]!.methods[name] = fn }
        case .enumType:
            if isStatic { enumDefs[typeName]!.staticMembers[name] = .function(fn) }
            else        { enumDefs[typeName]!.methods[name] = fn }
        case .builtin:
            var ext = extensions[typeName] ?? ExtensionMembers()
            if isStatic { ext.staticMembers[name] = .function(fn) }
            else        { ext.methods[name] = fn }
            extensions[typeName] = ext
        case .unknown: break
        }
    }

    private func installComputed(
        name: String, getter: Function,
        target: ExtensionTarget, typeName: String
    ) {
        switch target {
        case .structType:
            structDefs[typeName]!.computedProperties[name] = getter
        case .enumType:
            // EnumDef doesn't currently have a computed-property slot;
            // store as a method invoked via the property-access fallback.
            enumDefs[typeName]!.methods[name] = getter
        case .builtin:
            var ext = extensions[typeName] ?? ExtensionMembers()
            ext.computedProperties[name] = getter
            extensions[typeName] = ext
        case .unknown: break
        }
    }

    private func installStaticValue(
        name: String, value: Value,
        target: ExtensionTarget, typeName: String
    ) {
        switch target {
        case .structType: structDefs[typeName]!.staticMembers[name] = value
        case .enumType:   enumDefs[typeName]!.staticMembers[name] = value
        case .builtin:
            var ext = extensions[typeName] ?? ExtensionMembers()
            ext.staticMembers[name] = value
            extensions[typeName] = ext
        case .unknown: break
        }
    }

    /// Look up a name in the user extensions for a given type. Used by
    /// invokeMethod / lookupProperty on built-in receivers as a fallback
    /// after the built-in switch fails. Consults the flat `bridges`
    /// table first, then falls through to the legacy `extensions[]`
    /// storage.
    func extensionMethod(typeName: String, name: String) -> Function? {
        let key = bridgeKey(forMethod: name, on: typeName, labels: [])
        if case .method(let body)? = bridges[key] {
            return Function(
                name: key, parameters: [],
                kind: .builtinMethod(body)
            )
        }
        return extensions[typeName]?.methods[name]
    }

    func extensionComputedProperty(typeName: String, name: String) -> Function? {
        let key = bridgeKey(forComputedProperty: name, on: typeName)
        if case .computed(let body)? = bridges[key] {
            return Function(
                name: key, parameters: [],
                kind: .builtinMethod({ recv, _ in try await body(recv) })
            )
        }
        return extensions[typeName]?.computedProperties[name]
    }

    /// Invoke an extension method on a built-in receiver. Dispatches on
    /// the function kind:
    ///   - `.builtinMethod`: native closure that receives `(receiver, args)`
    ///     directly (used for `BuiltinModule` registrations).
    ///   - `.user`: SwiftScript function body — bind `self` and run it.
    ///   - `.builtin`: receiver-less native closure; treats `args` as-is.
    func invokeBuiltinExtensionMethod(
        _ fn: Function,
        on receiver: Value,
        args: [Value]
    ) async throws -> Value {
        switch fn.kind {
        case .builtinMethod(let body):
            return try await body(receiver, args)
        case .builtin(let body):
            return try await body(args)
        case .user(let body, let capturedScope):
            let callScope = Scope(parent: capturedScope)
            callScope.bind("self", value: receiver, mutable: false)
            guard args.count == fn.parameters.count else {
                throw RuntimeError.invalid(
                    "\(fn.name): expected \(fn.parameters.count) argument(s), got \(args.count)"
                )
            }
            for (param, value) in zip(fn.parameters, args) {
                callScope.bind(param.name, value: value, mutable: false)
            }
            returnTypeStack.append(fn.returnType)
            defer { returnTypeStack.removeLast() }
            do {
                var last: Value = .void
                for item in body {
                    last = try await execute(item: item, in: callScope)
                }
                return last
            } catch let signal as ReturnSignal {
                return signal.value
            }
        }
    }
}
