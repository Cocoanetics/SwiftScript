import SwiftSyntax

extension Interpreter {
    /// Register an `enum Foo { case … }` declaration.
    func execute(enumDecl: EnumDeclSyntax, in scope: Scope) async throws -> Value {
        let name = enumDecl.name.text

        // Detect a raw type from the inheritance clause: `enum X: Int { … }`.
        var rawType: String? = nil
        if let inheritance = enumDecl.inheritanceClause {
            for type in inheritance.inheritedTypes {
                if let identType = type.type.as(IdentifierTypeSyntax.self) {
                    let n = identType.name.text
                    if n == "Int" || n == "String" { rawType = n; break }
                }
            }
        }

        var cases: [EnumDef.Case] = []
        var methods: [String: Function] = [:]
        var staticMembers: [String: Value] = [:]
        var nextIntRawValue: Int = 0

        for member in enumDecl.memberBlock.members {
            let decl = member.decl
            if let caseDecl = decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    let caseName = element.name.text
                    let arity = element.parameterClause?.parameters.count ?? 0

                    var rawValue: Value? = nil
                    if let rawType {
                        if let initClause = element.rawValue {
                            let v = try await evaluate(initClause.value, in: scope)
                            rawValue = v
                            // Update the int counter so subsequent
                            // implicit values continue from this one.
                            if rawType == "Int", case .int(let i) = v {
                                nextIntRawValue = i + 1
                            }
                        } else {
                            switch rawType {
                            case "Int":
                                rawValue = .int(nextIntRawValue)
                                nextIntRawValue += 1
                            case "String":
                                // Default raw value for String enums is the case name.
                                rawValue = .string(caseName)
                            default: break
                            }
                        }
                    }
                    cases.append(EnumDef.Case(
                        name: caseName, arity: arity, rawValue: rawValue
                    ))
                }
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
                let fn = Function(
                    name: "\(name).\(methodName)",
                    parameters: params,
                    returnType: funcDecl.signature.returnClause?.type,
                    isMutating: false,
                    kind: .user(body: body.statements, capturedScope: scope)
                )
                if isStatic {
                    staticMembers[methodName] = .function(fn)
                } else {
                    methods[methodName] = fn
                }
            } else if let varDecl = decl.as(VariableDeclSyntax.self) {
                // Computed properties — `var label: String { switch … }`.
                // Stored properties aren't allowed on enums in Swift, so
                // any binding here must have an accessor block.
                let isStatic = varDecl.modifiers.contains {
                    $0.name.tokenKind == .keyword(.static)
                }
                for binding in varDecl.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                          let accessorBlock = binding.accessorBlock
                    else { continue }
                    let propName = ident.identifier.text
                    let body = try extractGetterBody(accessorBlock)
                    let fn = Function(
                        name: "\(name).\(propName)",
                        parameters: [],
                        returnType: binding.typeAnnotation?.type,
                        kind: .user(body: body, capturedScope: scope)
                    )
                    // Stored under `methods` so the existing zero-arg
                    // member-access fallback in `lookupProperty` finds it.
                    if isStatic {
                        staticMembers[propName] = .function(fn)
                    } else {
                        methods[propName] = fn
                    }
                }
            }
        }

        // Register the enum.
        enumDefs[name] = EnumDef(
            name: name,
            cases: cases,
            rawType: rawType,
            methods: methods,
            staticMembers: staticMembers
        )
        return .void
    }

    /// Construct an enum value, applying any associated-value coercion
    /// against the case's declared associated types is intentionally
    /// skipped — we don't track those here (yet).
    func makeEnumValue(typeName: String, caseName: String, args: [Value]) -> Value {
        return .enumValue(typeName: typeName, caseName: caseName, associatedValues: args)
    }

    /// If `expr` is an implicit-member expression (`.case`) and `expected`
    /// names a registered enum, resolve directly to the case value (no
    /// payload) or constructor function. Returns nil otherwise so the
    /// caller falls back to ordinary expression evaluation.
    func tryImplicitMember(_ expr: ExprSyntax, expecting: TypeSyntax?) -> Value? {
        guard let expected = expecting,
              let identType = expected.as(IdentifierTypeSyntax.self),
              enumDefs[identType.name.text] != nil
        else { return nil }
        guard let memberAccess = expr.as(MemberAccessExprSyntax.self),
              memberAccess.base == nil
        else { return nil }
        return enumCaseAccess(
            typeName: identType.name.text,
            caseName: memberAccess.declName.baseName.text
        )
    }

    /// Evaluate `expr`, but first try implicit-member resolution against
    /// `expecting`. Use this at every site that has a target type:
    /// let bindings, function arguments, return values.
    func evaluate(_ expr: ExprSyntax, expecting: TypeSyntax?, in scope: Scope) async throws -> Value {
        if let v = tryImplicitMember(expr, expecting: expecting) {
            return v
        }
        // `.case(args)` shorthand for enums with associated values.
        if let expected = expecting,
           let identType = expected.as(IdentifierTypeSyntax.self),
           enumDefs[identType.name.text] != nil,
           let call = expr.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil
        {
            let typeName = identType.name.text
            let caseName = memberAccess.declName.baseName.text
            guard let constructor = enumCaseAccess(typeName: typeName, caseName: caseName) else {
                throw RuntimeError.invalid("type '\(typeName)' has no case '\(caseName)'")
            }
            guard case .function(let fn) = constructor else {
                throw RuntimeError.invalid("'\(typeName).\(caseName)' takes no arguments")
            }
            let args = try await call.arguments.asyncMap { try await evaluate($0.expression, in: scope) }
            return try await invoke(fn, args: args)
        }
        return try await evaluate(expr, in: scope)
    }

    /// Look up a case on an enum type. Returns the constructed value for
    /// payload-less cases, or a Function that takes the payload args for
    /// cases with associated values.
    func enumCaseAccess(typeName: String, caseName: String) -> Value? {
        guard let def = enumDefs[typeName],
              let c = def.cases.first(where: { $0.name == caseName })
        else {
            return nil
        }
        if c.arity == 0 {
            return .enumValue(typeName: typeName, caseName: caseName, associatedValues: [])
        }
        // Payload case: produce a constructor function.
        let arity = c.arity
        let cn = caseName
        let tn = typeName
        let fn = Function(
            name: "\(typeName).\(caseName)",
            parameters: (0..<arity).map { _ in Function.Parameter(label: nil, name: "_arg", type: nil) },
            returnType: nil,
            kind: .builtin({ args in
                guard args.count == arity else {
                    throw RuntimeError.invalid(
                        "\(tn).\(cn): expected \(arity) associated values, got \(args.count)"
                    )
                }
                return .enumValue(typeName: tn, caseName: cn, associatedValues: args)
            })
        )
        return .function(fn)
    }
}
