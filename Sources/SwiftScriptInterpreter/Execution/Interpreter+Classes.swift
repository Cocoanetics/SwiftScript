import SwiftSyntax

extension Interpreter {
    /// Register a `class Foo: Bar { … }` declaration. Parsing mirrors
    /// `structDecl` — same kinds of members, same accessor handling — but
    /// instantiation produces a `ClassInstance` reference cell rather than
    /// a value, and we record the optional superclass so dispatch can walk
    /// the chain.
    func execute(classDecl: ClassDeclSyntax, in scope: Scope) async throws -> Value {
        return try await registerClassLike(
            name: classDecl.name.text,
            inheritance: classDecl.inheritanceClause,
            memberBlock: classDecl.memberBlock,
            in: scope
        )
    }

    /// `actor Foo { … }` — registered as a class, since this single-
    /// threaded interpreter has nothing to isolate. Methods are reachable
    /// directly without `await` (the `await` keyword is already a no-op
    /// at the expression level).
    func execute(actorDecl: ActorDeclSyntax, in scope: Scope) async throws -> Value {
        return try await registerClassLike(
            name: actorDecl.name.text,
            inheritance: actorDecl.inheritanceClause,
            memberBlock: actorDecl.memberBlock,
            in: scope
        )
    }

    private func registerClassLike(
        name: String,
        inheritance: InheritanceClauseSyntax?,
        memberBlock: MemberBlockSyntax,
        in scope: Scope
    ) async throws -> Value {
        // First inheritance entry that names a registered class is the
        // superclass; remaining entries are protocol conformances we
        // don't enforce statically. If the entry instead names a bridged
        // Foundation/stdlib type (Date, URL, …), record it as
        // `bridgedParent` so instantiation can wrap a real native value
        // and member lookup can fall through to the bridged surface.
        var superclassName: String? = nil
        var bridgedParent: String? = nil
        if let inherits = inheritance {
            for entry in inherits.inheritedTypes {
                guard let ident = entry.type.as(IdentifierTypeSyntax.self) else { continue }
                let parentName = resolveTypeName(ident.name.text)
                if classDefs[parentName] != nil {
                    superclassName = parentName
                    break
                }
                if isBridgedClassParent(parentName) {
                    bridgedParent = parentName
                    break
                }
            }
        }

        var properties: [StructDef.Property] = []
        var methods: [String: Function] = [:]
        var computed: [String: Function] = [:]
        var customInits: [Function] = []
        var dynamicMemberSubscript: Function? = nil
        var willSetObservers: [String: Function] = [:]
        var didSetObservers: [String: Function] = [:]
        var pendingStaticInits: [(name: String, expr: ExprSyntax)] = []
        var pendingStaticGetters: [(name: String, fn: Function)] = []
        var staticMethods: [String: Function] = [:]
        var requiredInitSignatures: [[String?]] = []
        // Names declared with / without `override`, tracked so we can
        // diagnose mismatches against the inheritance chain after the
        // member loop. Computed-property setters use `<name>__set__`,
        // so we filter those out before checking.
        var declaredOverrideMethods: Set<String> = []
        var declaredNonOverrideMethods: Set<String> = []
        var declaredOverrideComputed: Set<String> = []
        var declaredNonOverrideComputed: Set<String> = []
        var declaredOverrideObservedProps: Set<String> = []

        for member in memberBlock.members {
            let decl = member.decl
            if let varDecl = decl.as(VariableDeclSyntax.self) {
                let isStatic = varDecl.modifiers.contains {
                    $0.name.tokenKind == .keyword(.static)
                        || $0.name.tokenKind == .keyword(.class)
                }
                let isOverride = varDecl.modifiers.contains {
                    $0.name.tokenKind == .keyword(.override)
                }
                for binding in varDecl.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                        throw RuntimeError.unsupported(
                            "non-identifier class property pattern",
                            at: binding.positionAfterSkippingLeadingTrivia.utf8Offset
                        )
                    }
                    let propName = ident.identifier.text
                    if isStatic {
                        if let accessorBlock = binding.accessorBlock {
                            let body = try extractGetterBody(accessorBlock)
                            pendingStaticGetters.append((propName, Function(
                                name: "\(name).\(propName)",
                                parameters: [],
                                returnType: binding.typeAnnotation?.type,
                                staticContext: name,
                                kind: .user(body: body, capturedScope: scope)
                            )))
                        } else if let initializer = binding.initializer {
                            pendingStaticInits.append((propName, initializer.value))
                        }
                        continue
                    }
                    // Instance: stored, computed (get/set), or stored-with-observers.
                    if let accessorBlock = binding.accessorBlock {
                        let kind = classifyAccessorBlock(accessorBlock)
                        switch kind {
                        case .computed:
                            if isOverride {
                                declaredOverrideComputed.insert(propName)
                            } else {
                                declaredNonOverrideComputed.insert(propName)
                            }
                            computed[propName] = Function(
                                name: "\(name).\(propName)",
                                parameters: [],
                                returnType: binding.typeAnnotation?.type,
                                kind: .user(body: try extractGetterBody(accessorBlock), capturedScope: scope)
                            )
                            // Optional `set { … }` — install as a setter
                            // function; member-assign consults it.
                            if let setter = extractSetterBody(accessorBlock) {
                                let paramName = setter.parameterName ?? "newValue"
                                let setFn = Function(
                                    name: "\(name).\(propName).set",
                                    parameters: [.init(label: nil, name: paramName)],
                                    kind: .user(body: setter.body, capturedScope: scope)
                                )
                                // Stored alongside the getter under a
                                // distinct key so dispatch can find both.
                                computed["\(propName)__set__"] = setFn
                            }
                        case .observed(let willSet, let didSet):
                            // Observed stored property. For an `override`
                            // declaration, the storage already exists on
                            // an ancestor — only attach the observers
                            // here. Otherwise also create the slot.
                            if let propType = binding.typeAnnotation?.type {
                                try validateType(propType)
                            }
                            if isOverride {
                                declaredOverrideObservedProps.insert(propName)
                            } else {
                                properties.append(StructDef.Property(
                                    name: propName,
                                    type: binding.typeAnnotation?.type,
                                    defaultValue: binding.initializer?.value
                                ))
                            }
                            if let willSet {
                                willSetObservers[propName] = Function(
                                    name: "\(name).\(propName).willSet",
                                    parameters: [.init(label: nil, name: willSet.parameterName ?? "newValue")],
                                    kind: .user(body: willSet.body, capturedScope: scope)
                                )
                            }
                            if let didSet {
                                didSetObservers[propName] = Function(
                                    name: "\(name).\(propName).didSet",
                                    parameters: [.init(label: nil, name: didSet.parameterName ?? "oldValue")],
                                    kind: .user(body: didSet.body, capturedScope: scope)
                                )
                            }
                        }
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
                let isRequired = initDecl.modifiers.contains {
                    $0.name.tokenKind == .keyword(.required)
                }
                if isRequired {
                    requiredInitSignatures.append(params.map { $0.label })
                }
                let isFailable = initDecl.optionalMark != nil
                customInits.append(Function(
                    name: "\(name).init",
                    parameters: params,
                    isFailable: isFailable,
                    kind: .user(body: body.statements, capturedScope: scope)
                ))
            } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
                let methodName = funcDecl.name.text
                guard let body = funcDecl.body else { continue }
                let params = funcDecl.signature.parameterClause.parameters.map { p -> Function.Parameter in
                    let firstName = p.firstName.text
                    let label = (firstName == "_") ? nil : firstName
                    let internalName = (p.secondName?.text) ?? firstName
                    return Function.Parameter(
                        label: label, name: internalName,
                        type: p.type,
                        isInout: paramIsInout(p.type)
                    )
                }
                let isStatic = funcDecl.modifiers.contains {
                    $0.name.tokenKind == .keyword(.static)
                        || $0.name.tokenKind == .keyword(.class)
                }
                let isOverrideMethod = funcDecl.modifiers.contains {
                    $0.name.tokenKind == .keyword(.override)
                }
                if !isStatic {
                    if isOverrideMethod {
                        declaredOverrideMethods.insert(methodName)
                    } else {
                        declaredNonOverrideMethods.insert(methodName)
                    }
                }
                let fn = Function(
                    name: "\(name).\(methodName)",
                    parameters: params,
                    returnType: funcDecl.signature.returnClause?.type,
                    staticContext: isStatic ? name : nil,
                    kind: .user(body: body.statements, capturedScope: scope)
                )
                if isStatic {
                    staticMethods[methodName] = fn
                } else {
                    methods[methodName] = fn
                }
            } else if let subscriptDecl = decl.as(SubscriptDeclSyntax.self) {
                if let fn = makeDynamicMemberSubscript(subscriptDecl, owner: name, scope: scope) {
                    dynamicMemberSubscript = fn
                }
            }
        }

        // Override-keyword diagnostics: child members must use `override`
        // iff the same name exists in an ancestor.
        if let parentName = superclassName {
            let parentChain = classDefChain(parentName)
            func parentHasMethod(_ n: String) -> Bool {
                parentChain.contains { $0.methods[n] != nil }
            }
            func parentHasComputedOrStored(_ n: String) -> Bool {
                parentChain.contains {
                    $0.computedProperties[n] != nil
                        || $0.properties.contains(where: { $0.name == n })
                }
            }
            for n in declaredOverrideMethods where !parentHasMethod(n) {
                throw RuntimeError.invalid(
                    "method does not override any method from its superclass"
                )
            }
            for n in declaredNonOverrideMethods where parentHasMethod(n) {
                throw RuntimeError.invalid(
                    "overriding declaration requires an 'override' keyword"
                )
            }
            for n in declaredOverrideComputed where !parentHasComputedOrStored(n) {
                throw RuntimeError.invalid(
                    "property does not override any property from its superclass"
                )
            }
            for n in declaredNonOverrideComputed where parentHasComputedOrStored(n) {
                throw RuntimeError.invalid(
                    "overriding declaration requires an 'override' keyword"
                )
            }
            for n in declaredOverrideObservedProps where !parentHasComputedOrStored(n) {
                throw RuntimeError.invalid(
                    "property does not override any property from its superclass"
                )
            }
            // `required` initializer: when this class has its own custom
            // inits, every required init signature in any ancestor must
            // be present in our customInits list (matched by labels).
            if !customInits.isEmpty {
                for ancestor in parentChain {
                    for sig in ancestor.requiredInitSignatures {
                        let provided = customInits.contains { fn in
                            fn.parameters.map { $0.label } == sig
                        }
                        if !provided {
                            let initDesc = "init(\(sig.map { ($0 ?? "_") + ":" }.joined()))"
                            throw RuntimeError.invalid(
                                "'required' initializer '\(initDesc)' must be provided by subclass of '\(ancestor.name)'"
                            )
                        }
                    }
                }
            }
        } else {
            // No parent: any `override` is a stand-alone error.
            for _ in declaredOverrideMethods {
                throw RuntimeError.invalid(
                    "method does not override any method from its superclass"
                )
            }
            for _ in declaredOverrideComputed {
                throw RuntimeError.invalid(
                    "property does not override any property from its superclass"
                )
            }
            for _ in declaredOverrideObservedProps {
                throw RuntimeError.invalid(
                    "property does not override any property from its superclass"
                )
            }
        }

        classDefs[name] = ClassDef(
            name: name,
            superclass: superclassName,
            bridgedParent: bridgedParent,
            properties: properties,
            methods: methods,
            computedProperties: computed,
            customInits: customInits,
            staticMembers: [:],
            willSetObservers: willSetObservers,
            didSetObservers: didSetObservers,
            requiredInitSignatures: requiredInitSignatures,
            dynamicMemberSubscript: dynamicMemberSubscript
        )

        for (memberName, expr) in pendingStaticInits {
            classDefs[name]!.staticMembers[memberName] = try await evaluate(expr, in: scope)
        }
        for (memberName, getter) in pendingStaticGetters {
            classDefs[name]!.staticMembers[memberName] = try await invoke(getter, args: [])
        }
        for (memberName, fn) in staticMethods {
            classDefs[name]!.staticMembers[memberName] = .function(fn)
        }
        return .void
    }

    /// Static-member resolution result. `owningType` is the type that
    /// actually stores the member (could be an ancestor class for
    /// inherited statics); `kind` distinguishes struct vs class so
    /// writeback hits the right map.
    enum StaticOwnerKind { case structType, classType }
    struct StaticMemberInfo {
        let owningType: String
        let kind: StaticOwnerKind
        let value: Value
    }

    /// Look up `name` as a static member of `owner` (and ancestors when
    /// owner is a class). Returns the value plus enough info for
    /// `writeStaticMember` to write back to the right slot.
    func readStaticMember(owner: String, name: String) -> StaticMemberInfo? {
        if let v = structDefs[owner]?.staticMembers[name] {
            return StaticMemberInfo(owningType: owner, kind: .structType, value: v)
        }
        if classDefs[owner] != nil {
            for d in classDefChain(owner) {
                if let v = d.staticMembers[name] {
                    return StaticMemberInfo(owningType: d.name, kind: .classType, value: v)
                }
            }
        }
        return nil
    }

    /// Companion to `readStaticMember` — write back to the slot the
    /// resolver returned.
    func writeStaticMember(owner: String, kind: StaticOwnerKind, name: String, value: Value) {
        switch kind {
        case .structType: structDefs[owner]?.staticMembers[name] = value
        case .classType:  classDefs[owner]?.staticMembers[name] = value
        }
    }

    /// True if `name` is a bridged Foundation/stdlib type that script
    /// classes can wrap. We treat any type with registered `extensions`
    /// (initializers, methods, computeds, or static members) as
    /// wrappable — that's the same set the user can already access via
    /// `T(…)` calls and member dispatch.
    func isBridgedClassParent(_ name: String) -> Bool {
        guard let ext = extensions[name] else { return false }
        return !ext.initializers.isEmpty
            || !ext.methods.isEmpty
            || !ext.computedProperties.isEmpty
            || !ext.staticMembers.isEmpty
    }

    /// Build the synthetic `.opaque` value that represents the bridged
    /// half of a wrapper instance. Used when falling through to bridged
    /// extension methods/properties — they take a `Value` receiver.
    func wrappedBridgedValue(_ inst: ClassInstance) -> Value? {
        guard let parent = classDefs[inst.typeName]?.bridgedParent,
              let base = inst.bridgedBase
        else { return nil }
        return .opaque(typeName: parent, value: base)
    }

    /// Walk `def` plus each ancestor in turn so dispatch can find an
    /// inherited member without each call site re-implementing the walk.
    /// `child-first` ordering — overrides shadow parents naturally.
    func classDefChain(_ name: String) -> [ClassDef] {
        var chain: [ClassDef] = []
        var cur: String? = name
        var seen: Set<String> = []
        while let n = cur, !seen.contains(n), let def = classDefs[n] {
            chain.append(def)
            seen.insert(n)
            cur = def.superclass
        }
        return chain
    }

    /// Find a method on `def` or any ancestor. Used by call sites that
    /// already hit the receiver's def — we don't want every site to
    /// repeat the walk.
    func lookupClassMethod(on def: ClassDef, _ name: String) -> (Function, ClassDef)? {
        for d in classDefChain(def.name) {
            if let m = d.methods[name] { return (m, d) }
        }
        return nil
    }

    /// Same shape as `lookupClassMethod` but for computed-property getters.
    func lookupClassComputed(on def: ClassDef, _ name: String) -> Function? {
        for d in classDefChain(def.name) {
            if let g = d.computedProperties[name] { return g }
        }
        return nil
    }

    /// Find a setter (`set { … }`) for a computed property along the
    /// inheritance chain. Stored under the synthetic `<name>__set__` key
    /// in the same `computedProperties` map.
    func findClassSetter(on def: ClassDef, _ name: String) -> Function? {
        for d in classDefChain(def.name) {
            if let s = d.computedProperties["\(name)__set__"] { return s }
        }
        return nil
    }

    func lookupClassWillSet(on def: ClassDef, _ name: String) -> Function? {
        for d in classDefChain(def.name) {
            if let f = d.willSetObservers[name] { return f }
        }
        return nil
    }

    func lookupClassDidSet(on def: ClassDef, _ name: String) -> Function? {
        for d in classDefChain(def.name) {
            if let f = d.didSetObservers[name] { return f }
        }
        return nil
    }

    /// Dispatch a `super.<member>(...)` call. `currentClass` is the class
    /// whose body we're executing — we go one rung up the chain and find
    /// either an init (for `super.init`) or a method/computed property.
    /// The receiving `self` is the current `self` from scope so writes
    /// through the body still land on the active instance.
    func invokeSuperCall(
        currentClass: String,
        memberName: String,
        call: FunctionCallExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        guard let curDef = classDefs[currentClass] else {
            throw RuntimeError.invalid("'super' used outside a class context")
        }
        guard let parentName = curDef.superclass,
              let parentDef = classDefs[parentName]
        else {
            throw RuntimeError.invalid(
                "class '\(currentClass)' has no superclass to dispatch to"
            )
        }
        // Evaluate args.
        var args: [Value] = []
        for argSyntax in call.arguments {
            args.append(try await evaluate(argSyntax.expression, in: scope))
        }
        // `super.init(...)` runs the parent init *on the current self*.
        if memberName == "init" {
            // Find the parent init by label match.
            let labels = call.arguments.map { $0.label?.text }
            for fn in parentDef.customInits {
                guard fn.parameters.count == labels.count else { continue }
                let paramLabels = fn.parameters.map { $0.label }
                if zip(paramLabels, labels).allSatisfy({ $0 == $1 }) {
                    return try await runSuperInit(fn, on: parentDef, args: args, in: scope)
                }
            }
            // No matching custom init; treat as memberwise assignment of
            // the parent's stored properties (the most permissive thing
            // for the script-tour case).
            guard let selfBinding = scope.lookup("self"),
                  case .classInstance(let inst) = selfBinding.value
            else {
                throw RuntimeError.invalid("super.init: 'self' not bound")
            }
            for (i, prop) in parentDef.properties.enumerated() {
                if i < args.count, let idx = inst.fields.firstIndex(where: { $0.name == prop.name }) {
                    inst.fields[idx].value = args[i]
                }
            }
            return .void
        }
        // `super.method(...)` — dispatch to the parent's method.
        guard let (method, owningDef) = lookupClassMethod(on: parentDef, memberName) else {
            throw RuntimeError.invalid(
                "'\(parentName)' has no method '\(memberName)'"
            )
        }
        guard let selfBinding = scope.lookup("self"),
              case .classInstance(let inst) = selfBinding.value
        else {
            throw RuntimeError.invalid("super.\(memberName): 'self' not bound")
        }
        return try await invokeClassMethod(method, on: inst, def: owningDef, args: args)
    }

    /// Run the parent's init body using the current `self` as the
    /// receiver. The parent's init may itself call `super.init(...)` to
    /// chain further up; the class-context stack tracks where we are.
    private func runSuperInit(
        _ fn: Function,
        on parentDef: ClassDef,
        args: [Value],
        in scope: Scope
    ) async throws -> Value {
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("init must be a user-defined function")
        }
        guard let selfBinding = scope.lookup("self") else {
            throw RuntimeError.invalid("super.init: 'self' not bound")
        }
        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: selfBinding.value, mutable: true)
        for (param, value) in zip(fn.parameters, args) {
            callScope.bind(param.name, value: value, mutable: false)
        }
        currentClassContextStack.append(parentDef.name)
        defer { currentClassContextStack.removeLast() }
        do {
            for item in body {
                _ = try await execute(item: item, in: callScope)
            }
        } catch is ReturnSignal {
            // `return` inside an init means "stop here" — fine.
        }
        return .void
    }

    /// Aggregate all stored properties along the inheritance chain, with
    /// the root's properties first and leaf's last — so a child's
    /// `init(...)` body assigns to the same offsets the parent's body
    /// already populated.
    func storedPropertyChain(of def: ClassDef) -> [StructDef.Property] {
        var collected: [StructDef.Property] = []
        for d in classDefChain(def.name).reversed() {
            collected.append(contentsOf: d.properties)
        }
        return collected
    }

    /// Run `Foo(...)`. Dispatch order: matching custom init → memberwise
    /// auto-init (no-arg if all properties default; labeled if any do not).
    func instantiateClass(
        _ def: ClassDef,
        call: FunctionCallExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        let argSyntaxes = Array(call.arguments)
        let callLabels = argSyntaxes.map { $0.label?.text }

        // Custom init wins if any class on the chain declares one whose
        // labels match. Walk leaf-first so child overrides parent inits.
        for cls in classDefChain(def.name) {
            for fn in cls.customInits {
                guard fn.parameters.count == callLabels.count else { continue }
                let paramLabels = fn.parameters.map { $0.label }
                if zip(paramLabels, callLabels).allSatisfy({ $0 == $1 }) {
                    return try await invokeClassInit(fn, def: def, call: call, in: scope)
                }
            }
        }

        // Bridged-parent wrapper class without a matching custom init:
        // forward the call to the parent's bridged initializer to
        // populate `bridgedBase`, then initialize script fields from
        // their defaults.
        if let parentName = def.bridgedParent,
           let parentInits = extensions[parentName]?.initializers
        {
            let labels = argSyntaxes.map { $0.label?.text ?? "_" }
            guard let initFn = parentInits[labels] else {
                throw RuntimeError.invalid(
                    "no matching initializer on bridged parent '\(parentName)' for labels \(labels)"
                )
            }
            // Evaluate args using the existing bridged-init context so
            // implicit-member access (`.utf8`, `.gregorian`, …) resolves.
            var args: [Value] = []
            for arg in call.arguments {
                let label = arg.label?.text ?? "_"
                let context = implicitContextForInit(typeName: parentName, label: label)
                args.append(try await evaluateArg(
                    arg.expression, label: label, contextType: context, in: scope
                ))
            }
            let baseValue = try await invoke(initFn, args: args)
            // Failable inits (`URL(string:)`) return `Optional<T>`.
            // Propagate the optionality through the wrapper so that
            // `LabeledURL(string: "…")!` behaves like the underlying
            // bridged init does.
            let isFailable: Bool
            let payload: Any?
            switch baseValue {
            case .optional(.none):
                return .optional(nil)
            case .optional(.some(.opaque(_, let p))):
                isFailable = true; payload = p
            case .opaque(_, let p):
                isFailable = false; payload = p
            default:
                throw RuntimeError.invalid(
                    "bridged init for '\(parentName)' returned an unexpected value: \(baseValue)"
                )
            }
            // Script fields: only those with declared defaults can be
            // populated here; the script can supply a custom init for
            // anything more elaborate.
            var fields: [StructField] = []
            for prop in storedPropertyChain(of: def) {
                guard let defaultExpr = prop.defaultValue else {
                    throw RuntimeError.invalid(
                        "wrapper class '\(def.name)' field '\(prop.name)' needs a default value or a custom init"
                    )
                }
                var value = try await evaluate(defaultExpr, in: scope)
                if let propType = prop.type {
                    value = try await coerce(
                        value: value, expr: defaultExpr,
                        toType: propType, in: .binding
                    )
                }
                fields.append(StructField(name: prop.name, value: value))
            }
            let inst = ClassInstance(
                typeName: def.name, fields: fields, bridgedBase: payload
            )
            return isFailable ? .optional(.classInstance(inst)) : .classInstance(inst)
        }

        // Auto memberwise init across the inheritance chain. The full
        // chain's stored properties become parameters, in root → leaf
        // order, matching how Swift presents the synthesized init.
        let allProps = storedPropertyChain(of: def)
        guard argSyntaxes.count <= allProps.count else {
            throw RuntimeError.invalid("extra argument in call")
        }
        // Trailing-defaults rule: properties without defaults must be
        // supplied; properties with defaults may be omitted.
        for i in argSyntaxes.count..<allProps.count {
            if allProps[i].defaultValue == nil {
                throw RuntimeError.invalid(
                    "missing argument for parameter '\(allProps[i].name)' in call"
                )
            }
        }
        var fields: [StructField] = []
        for (i, prop) in allProps.enumerated() {
            if i < argSyntaxes.count {
                let argSyntax = argSyntaxes[i]
                if argSyntax.label?.text != prop.name {
                    throw RuntimeError.invalid(
                        "incorrect argument label in call (have '\(argSyntax.label?.text ?? "_"):', expected '\(prop.name):')"
                    )
                }
                var value = try await evaluate(
                    argSyntax.expression, expecting: prop.type, in: scope
                )
                if let propType = prop.type {
                    value = try await coerce(
                        value: value, expr: argSyntax.expression,
                        toType: propType, in: .argument
                    )
                }
                fields.append(StructField(name: prop.name, value: value))
            } else {
                let defaultExpr = prop.defaultValue!
                var value = try await evaluate(defaultExpr, in: scope)
                // Coerce against the declared type so `var speed: Double = 0`
                // stores `0.0`, not `0` — important for downstream
                // arithmetic and string-interpolation formatting.
                if let propType = prop.type {
                    value = try await coerce(
                        value: value, expr: defaultExpr,
                        toType: propType, in: .binding
                    )
                }
                fields.append(StructField(name: prop.name, value: value))
            }
        }
        return .classInstance(ClassInstance(typeName: def.name, fields: fields))
    }

    /// Run a custom init. The body's `self` is a mutable reference to the
    /// freshly allocated `ClassInstance`. We pre-seed each stored property
    /// (including ancestors') with its declared default — or `.void` if
    /// there isn't one — so that `self.x = …` writes inside the body land
    /// in a sensible slot. `super.init(...)` is intercepted by the call
    /// evaluator; here we just provide a usable `self` to chain through.
    func invokeClassInit(
        _ fn: Function,
        def: ClassDef,
        call: FunctionCallExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("init must be a user-defined function")
        }
        let argSyntaxes = Array(call.arguments)
        var args: [Value] = []
        for (i, argSyntax) in argSyntaxes.enumerated() {
            let paramType = (i < fn.parameters.count) ? fn.parameters[i].type : nil
            var value = try await evaluate(
                argSyntax.expression, expecting: paramType, in: scope
            )
            if let pt = paramType {
                value = try await coerce(
                    value: value, expr: argSyntax.expression,
                    toType: pt, in: .argument
                )
            }
            args.append(value)
        }

        // Pre-seed self with chain-collected stored properties, each set
        // to its default (or .void if none). The init body fills in any
        // unset ones via `self.x = …` writes.
        var fields: [StructField] = []
        for prop in storedPropertyChain(of: def) {
            var initial: Value
            if let defaultExpr = prop.defaultValue {
                initial = try await evaluate(defaultExpr, in: scope)
                if let propType = prop.type {
                    initial = try await coerce(
                        value: initial, expr: defaultExpr,
                        toType: propType, in: .binding
                    )
                }
            } else {
                initial = .void
            }
            fields.append(StructField(name: prop.name, value: initial))
        }
        let inst = ClassInstance(typeName: def.name, fields: fields)

        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: .classInstance(inst), mutable: true)
        for (param, value) in zip(fn.parameters, args) {
            callScope.bind(param.name, value: value, mutable: false)
        }
        // Push the static-context-style class context so `super.init(...)`
        // inside the body can find the parent's init via `currentClassContext`.
        currentClassContextStack.append(def.name)
        instancesInInit.insert(ObjectIdentifier(inst))
        defer {
            currentClassContextStack.removeLast()
            instancesInInit.remove(ObjectIdentifier(inst))
        }
        var failedInit = false
        do {
            for item in body {
                _ = try await execute(item: item, in: callScope)
            }
        } catch let signal as ReturnSignal {
            // `return` is allowed in inits as an early exit. For
            // failable inits, `return nil` produces `.optional(nil)`
            // and signals construction failure.
            if fn.isFailable, case .optional(.none) = signal.value {
                failedInit = true
            }
        }
        if fn.isFailable {
            return failedInit ? .optional(nil) : .optional(.classInstance(inst))
        }
        return .classInstance(inst)
    }

    /// Invoke a class method/getter with `self` bound to the instance.
    /// Mutations propagate via the reference cell — no writeback needed.
    func invokeClassMethod(
        _ fn: Function,
        on inst: ClassInstance,
        def: ClassDef,
        args: [Value]
    ) async throws -> Value {
        guard case .user(let body, let capturedScope) = fn.kind else {
            throw RuntimeError.invalid("class method must be a user-defined function")
        }
        let callScope = Scope(parent: capturedScope)
        callScope.bind("self", value: .classInstance(inst), mutable: true)
        guard args.count == fn.parameters.count else {
            if args.count > fn.parameters.count {
                throw RuntimeError.invalid("extra argument in call")
            }
            throw RuntimeError.invalid(
                "missing argument for parameter #\(args.count + 1) in call"
            )
        }
        for (param, value) in zip(fn.parameters, args) {
            callScope.bind(param.name, value: value, mutable: false)
        }

        currentClassContextStack.append(def.name)
        defer { currentClassContextStack.removeLast() }
        returnTypeStack.append(fn.returnType)
        defer { returnTypeStack.removeLast() }

        var caught: Error? = nil
        var last: Value = .void
        do {
            for item in body {
                last = try await execute(item: item, in: callScope)
            }
        } catch let signal as ReturnSignal {
            last = signal.value
        } catch {
            caught = error
        }
        await runDeferred(in: callScope)
        if let caught { throw caught }
        return last
    }
}

// MARK: - Accessor classification

private enum AccessorKind {
    case computed
    case observed(willSet: ObservedAccessor?, didSet: ObservedAccessor?)
}

struct ObservedAccessor {
    let parameterName: String?
    let body: CodeBlockItemListSyntax
}

struct SetterAccessor {
    let parameterName: String?
    let body: CodeBlockItemListSyntax
}

private func classifyAccessorBlock(_ block: AccessorBlockSyntax) -> AccessorKind {
    switch block.accessors {
    case .getter:
        return .computed
    case .accessors(let accs):
        var hasGet = false
        var willSet: ObservedAccessor? = nil
        var didSet: ObservedAccessor? = nil
        for acc in accs {
            switch acc.accessorSpecifier.tokenKind {
            case .keyword(.get):     hasGet = true
            case .keyword(.set):     hasGet = true // computed if any of get/set present
            case .keyword(.willSet):
                if let body = acc.body {
                    willSet = ObservedAccessor(
                        parameterName: acc.parameters?.name.text,
                        body: body.statements
                    )
                }
            case .keyword(.didSet):
                if let body = acc.body {
                    didSet = ObservedAccessor(
                        parameterName: acc.parameters?.name.text,
                        body: body.statements
                    )
                }
            default: break
            }
        }
        if hasGet { return .computed }
        return .observed(willSet: willSet, didSet: didSet)
    }
}

func extractSetterBody(_ block: AccessorBlockSyntax) -> SetterAccessor? {
    guard case .accessors(let accs) = block.accessors else { return nil }
    for acc in accs {
        if acc.accessorSpecifier.tokenKind == .keyword(.set), let body = acc.body {
            return SetterAccessor(
                parameterName: acc.parameters?.name.text,
                body: body.statements
            )
        }
    }
    return nil
}
