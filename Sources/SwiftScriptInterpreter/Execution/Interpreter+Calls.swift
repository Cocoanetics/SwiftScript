import SwiftSyntax

extension Interpreter {
    func evaluate(call: FunctionCallExprSyntax, in scope: Scope) async throws -> Value {
        if startsOptionalChain(ExprSyntax(call)) {
            return try await evaluateInOptionalChain(ExprSyntax(call), in: scope)
        }
        // `Stack<Int>(...)` — strip generic specialization. We don't track
        // type parameters at runtime, so the specialized form is identical
        // to the unspecialized one for dispatch purposes.
        if let spec = call.calledExpression.as(GenericSpecializationExprSyntax.self) {
            let stripped = call.with(\.calledExpression, spec.expression)
            return try await evaluate(call: stripped, in: scope)
        }
        // Memberwise init: `Foo(x: 1, y: 2)` where `Foo` is a registered
        // struct (after resolving typealiases).
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let structDef = structDefs[resolveTypeName(ref.baseName.text)]
        {
            return try await instantiateStruct(structDef, call: call, in: scope)
        }
        // Class instantiation: `Foo()` / `Foo(x:)`. Same dispatch shape as
        // structs — go through the dedicated class instantiator since
        // reference semantics and inheritance need different handling.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let classDef = classDefs[resolveTypeName(ref.baseName.text)]
        {
            return try await instantiateClass(classDef, call: call, in: scope)
        }
        // Enum's auto-synthesized `init?(rawValue:)` — only valid for
        // raw-value enums and only with the single `rawValue:` label.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let enumDef = enumDefs[resolveTypeName(ref.baseName.text)]
        {
            let argSyntaxes = Array(call.arguments)
            guard argSyntaxes.count == 1, argSyntaxes[0].label?.text == "rawValue" else {
                throw RuntimeError.invalid(
                    "no exact matches in call to initializer for '\(enumDef.name)'"
                )
            }
            guard enumDef.rawType != nil else {
                throw RuntimeError.invalid(
                    "'\(enumDef.name)' has no raw type; rawValue init unavailable"
                )
            }
            let rawValue = try await evaluate(argSyntaxes[0].expression, in: scope)
            if let match = enumDef.cases.first(where: { $0.rawValue == rawValue }) {
                return .optional(.enumValue(
                    typeName: enumDef.name,
                    caseName: match.name,
                    associatedValues: []
                ))
            }
            return .optional(nil)
        }
        // Built-in type initializer registered via `registerInit` (URL,
        // Date, UUID, CharacterSet, …). Keyed by the argument-label list,
        // matching the call site's labels in declaration order. We fall
        // through to other paths if no label list matches — `String` has
        // hand-rolled inits (`String(contentsOfFile:encoding:)`) that
        // live in `tryStringContentsOfFile` and need to remain reachable.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let inits = extensions[resolveTypeName(ref.baseName.text)]?.initializers,
           !inits.isEmpty
        {
            let typeName = resolveTypeName(ref.baseName.text)
            let labels = call.arguments.map { $0.label?.text ?? "_" }
            if let fn = inits[labels] {
                var args: [Value] = []
                for arg in call.arguments {
                    let label = arg.label?.text ?? "_"
                    let context = implicitContextForInit(typeName: typeName, label: label)
                    args.append(try await evaluateArg(
                        arg.expression,
                        label: label,
                        contextType: context,
                        in: scope
                    ))
                }
                return try await invoke(fn, args: args)
            }
        }

        // `print(items..., separator:, terminator:)` — registerBuiltin
        // closures don't see argument labels, so handle the labelled
        // form here and use the resolved separator/terminator. Falls
        // through if it isn't a `print` call.
        if let v = try await tryPrintCall(call, in: scope) {
            return v
        }

        // `[Int](repeating: …, count: …)` and `[Int]()` — array-initializer
        // sugar where the calledExpression is a single-element array literal
        // whose element is a type name.
        if let arrExpr = call.calledExpression.as(ArrayExprSyntax.self),
           arrExpr.elements.count == 1,
           let elementRef = arrExpr.elements.first?.expression.as(DeclReferenceExprSyntax.self),
           isTypeName(elementRef.baseName.text)
        {
            return try await evaluateTypedArrayInitializer(call, in: scope)
        }
        // `[String: Int]()` — empty typed-dictionary initializer. The
        // calledExpression parses as a dictionary literal whose only pair
        // is two type-name identifiers; only the no-arg form is supported.
        if isTypedDictInitializer(call), call.arguments.isEmpty,
           call.trailingClosure == nil
        {
            return .dict([])
        }
        // `String(contentsOfFile:encoding:)` — Foundation file read. Routed
        // here before the regular String(_:) builtin so the labelled-arg
        // form gets recognized.
        if let v = try await tryStringContentsOfFile(call, in: scope) {
            return v
        }
        // `str.write(toFile:atomically:encoding:)` — Foundation file write.
        // Pre-detected so we can skip evaluating the `.utf8` arg.
        if let v = try await tryStringWriteCall(call, in: scope) {
            return v
        }

        // `super.init(...)` / `super.method(...)` inside a class method.
        // The current class context tells us which class we're in; the
        // call dispatches to the parent's surface.
        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.base?.is(SuperExprSyntax.self) == true,
           let currentClass = currentClassContextStack.last
        {
            let memberName = memberAccess.declName.baseName.text
            return try await invokeSuperCall(
                currentClass: currentClass,
                memberName: memberName,
                call: call,
                in: scope
            )
        }

        // Method call: `receiver.method(args)`. Builtin methods accept raw
        // values, so no parameter-type coercion is applied here. Trailing
        // closure (if any) becomes the last argument. We also detect
        // *static* method calls (e.g. `Int.random(in:)`) where the receiver
        // is a type name, not a value.
        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = memberAccess.base
        {
            // Mutating instance methods that need lvalue access to the
            // receiver. `Bool.toggle()` and all of Array's in-place
            // mutators go through here.
            let methodName = memberAccess.declName.baseName.text
            if let ref = base.as(DeclReferenceExprSyntax.self),
               let result = try await tryMutatingMethodCall(
                   methodName: methodName,
                   varName: ref.baseName.text,
                   call: call,
                   in: scope
               )
            {
                return result
            }
            if let ref = base.as(DeclReferenceExprSyntax.self),
               isTypeName(ref.baseName.text)
            {
                let staticMember = try await lookupStaticMember(
                    typeName: ref.baseName.text,
                    member: memberAccess.declName.baseName.text,
                    at: memberAccess.positionAfterSkippingLeadingTrivia.utf8Offset
                )
                guard case .function(let fn) = staticMember else {
                    throw RuntimeError.invalid(
                        "'\(ref.baseName.text).\(memberAccess.declName.baseName.text)' is not callable"
                    )
                }
                var args = try await call.arguments.asyncMap { try await evaluate($0.expression, in: scope) }
                if let trailing = call.trailingClosure {
                    args.append(try await evaluate(closure: trailing, in: scope))
                    for extra in call.additionalTrailingClosures {
                        args.append(try await evaluate(closure: extra.closure, in: scope))
                    }
                }
                return try await invoke(fn, args: args)
            }
            let receiver = try await evaluate(base, in: scope)
            // User-defined struct methods: declared param types mean we
            // need the same coercion path as ordinary user-function calls
            // (otherwise `v.scaled(by: 2)` passes Int to a Double param).
            if case .structValue(let structTypeName, let fields) = receiver,
               let def = structDefs[structTypeName],
               let method = def.methods[methodName]
            {
                let argSyntaxes = Array(call.arguments)
                var args: [Value] = []
                args.reserveCapacity(argSyntaxes.count + (call.trailingClosure != nil ? 1 : 0))
                for (i, argSyntax) in argSyntaxes.enumerated() {
                    var value = try await evaluate(argSyntax.expression, in: scope)
                    if i < method.parameters.count, let paramType = method.parameters[i].type {
                        value = try await coerce(
                            value: value,
                            expr: argSyntax.expression,
                            toType: paramType,
                            in: .argument
                        )
                    }
                    args.append(value)
                }
                if let trailing = call.trailingClosure {
                    args.append(try await evaluate(closure: trailing, in: scope))
                    for extra in call.additionalTrailingClosures {
                        args.append(try await evaluate(closure: extra.closure, in: scope))
                    }
                }

                // Mutating methods need an lvalue receiver — `var.method()`
                // or any chain of property accesses ending at a stored
                // variable. We parse the chain, run the method on a copy,
                // then rebuild the chain bottom-up to write the new value
                // back to the root variable.
                if method.isMutating {
                    guard let path = parseLValuePath(base) else {
                        throw RuntimeError.invalid(
                            "cannot use mutating member '\(methodName)' on a non-variable receiver"
                        )
                    }
                    guard let binding = scope.lookup(path.base) else {
                        throw RuntimeError.invalid("cannot find '\(path.base)' in scope")
                    }
                    guard binding.mutable else {
                        throw RuntimeError.invalid(
                            "cannot use mutating member on immutable value: '\(path.base)' is a 'let' constant"
                        )
                    }
                    let (result, finalSelf) = try await invokeStructMethod(
                        method, on: receiver, fields: fields, args: args
                    )
                    try writeLValuePath(path, value: finalSelf, in: scope)
                    return result
                }

                let (result, _) = try await invokeStructMethod(
                    method, on: receiver, fields: fields, args: args
                )
                return result
            }

            // User-defined class methods: walk the inheritance chain to
            // find a method, then dispatch via `invokeClassMethod` (no
            // writeback — mutations land on the reference cell).
            if case .classInstance(let inst) = receiver,
               let def = classDefs[inst.typeName],
               let (method, owningDef) = lookupClassMethod(on: def, methodName)
            {
                let argSyntaxes = Array(call.arguments)
                var args: [Value] = []
                for (i, argSyntax) in argSyntaxes.enumerated() {
                    let paramType = (i < method.parameters.count) ? method.parameters[i].type : nil
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
                if let trailing = call.trailingClosure {
                    args.append(try await evaluate(closure: trailing, in: scope))
                    for extra in call.additionalTrailingClosures {
                        args.append(try await evaluate(closure: extra.closure, in: scope))
                    }
                }
                return try await invokeClassMethod(method, on: inst, def: owningDef, args: args)
            }

            // Wrapper-class method fallback: the script class doesn't
            // define `methodName`, but it wraps a bridged type whose
            // extension surface might. Re-dispatch the call with the
            // wrapped value as the receiver so the bridged method runs.
            if case .classInstance(let inst) = receiver,
               let wrapped = wrappedBridgedValue(inst)
            {
                let rewritten = call.with(\.calledExpression, ExprSyntax(
                    memberAccess.with(\.base, ExprSyntax(
                        DeclReferenceExprSyntax(baseName: .identifier("__wrapped__"))
                    ))
                ))
                let bridgedScope = Scope(parent: scope)
                bridgedScope.bind("__wrapped__", value: wrapped, mutable: false)
                return try await evaluate(call: rewritten, in: bridgedScope)
            }

            // Builtin methods: take raw values, no coercion. Implicit-member
            // arguments (`.whitespaces`) resolve against a known context type
            // for a small allowlist of methods — full bidirectional inference
            // is bigger than what we need here.
            let implicitContext = implicitMemberContext(method: methodName, receiver: receiver)
            var args: [Value] = []
            for arg in call.arguments {
                args.append(try await evaluateArg(
                    arg.expression,
                    label: arg.label?.text,
                    contextType: implicitContext,
                    in: scope
                ))
            }
            if let trailing = call.trailingClosure {
                args.append(try await evaluate(closure: trailing, in: scope))
                for extra in call.additionalTrailingClosures {
                    args.append(try await evaluate(closure: extra.closure, in: scope))
                }
            }
            return try await invokeMethod(
                methodName,
                on: receiver,
                args: args,
                at: call.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }

        // Implicit-self method dispatch: a bare-identifier call (`speak()`)
        // inside a class method body resolves to `self.speak()` when the
        // class — or any ancestor — defines that method. Otherwise we
        // fall through to the regular evaluator (top-level function,
        // closure-typed binding, etc.).
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           let selfBinding = scope.lookup("self"),
           case .classInstance(let inst) = selfBinding.value,
           let classDef = classDefs[inst.typeName],
           let (method, owningDef) = lookupClassMethod(on: classDef, ref.baseName.text)
        {
            let argSyntaxes = Array(call.arguments)
            var args: [Value] = []
            for (i, argSyntax) in argSyntaxes.enumerated() {
                let paramType = (i < method.parameters.count) ? method.parameters[i].type : nil
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
            if let trailing = call.trailingClosure {
                args.append(try await evaluate(closure: trailing, in: scope))
                for extra in call.additionalTrailingClosures {
                    args.append(try await evaluate(closure: extra.closure, in: scope))
                }
            }
            return try await invokeClassMethod(method, on: inst, def: owningDef, args: args)
        }

        let calleeValue = try await evaluate(call.calledExpression, in: scope)
        guard case .function(let fn) = calleeValue else {
            throw RuntimeError.invalid(
                "attempt to call non-function value (\(typeName(calleeValue)))"
            )
        }

        // Evaluate args alongside their syntax so we can coerce against
        // the parameter's declared type (literal-polymorphism rules).
        // Generic-parameter scope is pushed for the duration of arg
        // coercion AND the body execution, so type validation against
        // `T`-typed parameters resolves.
        if !fn.genericParameters.isEmpty {
            genericTypeParameters.append(Set(fn.genericParameters))
        }
        defer {
            if !fn.genericParameters.isEmpty { genericTypeParameters.removeLast() }
        }
        let argSyntaxes = Array(call.arguments)
        var args: [Value] = []
        args.reserveCapacity(argSyntaxes.count + (call.trailingClosure != nil ? 1 : 0))
        // Inout writebacks: for each `&x` arg, capture the underlying
        // l-value path so we can flush the body's final value back when
        // invoke returns. We carry the param index as well so we can
        // map back to the right parameter name.
        var inoutWritebacks: [(paramIdx: Int, write: (Value) throws -> Void)] = []
        for (i, argSyntax) in argSyntaxes.enumerated() {
            let paramType = (i < fn.parameters.count) ? fn.parameters[i].type : nil
            // `&x` — strip the `inout` marker, evaluate the underlying
            // expression, and arrange for writeback after the call.
            if let inoutExpr = argSyntax.expression.as(InOutExprSyntax.self) {
                let inner = inoutExpr.expression
                let value = try await evaluate(inner, in: scope)
                args.append(value)
                if i < fn.parameters.count, fn.parameters[i].isInout {
                    if let ref = inner.as(DeclReferenceExprSyntax.self) {
                        let name = ref.baseName.text
                        inoutWritebacks.append((i, { newValue in
                            guard scope.assign(name, value: newValue) else {
                                throw RuntimeError.invalid(
                                    "cannot pass immutable '\(name)' as inout argument"
                                )
                            }
                        }))
                    } else if let path = parseLValuePath(inner) {
                        inoutWritebacks.append((i, { newValue in
                            try self.writeLValuePath(path, value: newValue, in: scope)
                        }))
                    }
                }
                continue
            }
            var value = try await evaluate(argSyntax.expression, expecting: paramType, in: scope)
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
        // Trailing closure becomes the next positional argument.
        if let trailing = call.trailingClosure {
            args.append(try await evaluate(closure: trailing, in: scope))
            for extra in call.additionalTrailingClosures {
                args.append(try await evaluate(closure: extra.closure, in: scope))
            }
        }
        return try await invoke(fn, args: args, inoutWritebacks: inoutWritebacks)
    }

    func invoke(
        _ fn: Function,
        args: [Value],
        inoutWritebacks: [(paramIdx: Int, write: (Value) throws -> Void)] = []
    ) async throws -> Value {
        switch fn.kind {
        case .builtin(let body):
            return try await body(args)

        case .builtinMethod(let body):
            // A module-registered method invoked as a free function (no
            // receiver). Pass `.void` so the body can error if it needs one.
            return try await body(.void, args)

        case .user(let body, let capturedScope):
            // Generic-parameter scope for type validation inside the
            // body — `func swapEm<T>(...)` should let `T` resolve when
            // we coerce arguments against the declared parameter types.
            if !fn.genericParameters.isEmpty {
                genericTypeParameters.append(Set(fn.genericParameters))
            }
            defer {
                if !fn.genericParameters.isEmpty { genericTypeParameters.removeLast() }
            }
            if let staticOwner = fn.staticContext {
                staticContextStack.append(staticOwner)
            }
            defer {
                if fn.staticContext != nil { staticContextStack.removeLast() }
            }
            let callScope = Scope(parent: capturedScope)
            if fn.parameters.isEmpty {
                // Anonymous-args closure: bind $0, $1, … to whatever args
                // the caller passes. Body decides which $N to actually use.
                for (i, value) in args.enumerated() {
                    callScope.bind("$\(i)", value: value, mutable: false)
                }
            } else {
                // Tuple-pattern destructuring: closure declared as
                // `{ (i, v) in … }` has two parameters but is invoked
                // with a single tuple Value (e.g. by `enumerated().map`).
                // Spread the tuple into the params before the arity check.
                var effectiveArgs = args
                if args.count == 1,
                   case .tuple(let elements, _) = args[0],
                   elements.count == fn.parameters.count
                {
                    effectiveArgs = elements
                }
                // Variadic last parameter: collapse trailing args into a
                // single `.array` so the body sees `xs` as `[Int]`.
                if let last = fn.parameters.last, last.isVariadic {
                    let fixed = fn.parameters.count - 1
                    if effectiveArgs.count >= fixed {
                        let variadic = Array(effectiveArgs.dropFirst(fixed))
                        effectiveArgs = Array(effectiveArgs.prefix(fixed)) + [.array(variadic)]
                    }
                }
                // Default arguments: pad missing trailing args by evaluating
                // each parameter's `defaultValue` in the function's captured
                // scope. Stop at the first param without a default.
                while effectiveArgs.count < fn.parameters.count {
                    let paramIdx = effectiveArgs.count
                    guard let defaultExpr = fn.parameters[paramIdx].defaultValue else {
                        break
                    }
                    var value = try await evaluate(defaultExpr, in: capturedScope)
                    if let pt = fn.parameters[paramIdx].type {
                        value = try await coerce(
                            value: value,
                            expr: defaultExpr,
                            toType: pt,
                            in: .argument
                        )
                    }
                    effectiveArgs.append(value)
                }
                guard effectiveArgs.count == fn.parameters.count else {
                    if effectiveArgs.count > fn.parameters.count {
                        throw RuntimeError.invalid("extra argument in call")
                    }
                    throw RuntimeError.invalid("missing argument for parameter #\(effectiveArgs.count + 1) in call")
                }
                for (param, value) in zip(fn.parameters, effectiveArgs) {
                    // Inout params bind mutably so the body can `n += 1`.
                    callScope.bind(param.name, value: value, mutable: param.isInout)
                }
            }

            returnTypeStack.append(fn.returnType)
            defer { returnTypeStack.removeLast() }

            // Deferred bodies registered inside the function run on exit
            // regardless of how we leave (normal, return, or error).
            var caught: Error? = nil
            var last: Value = .void
            var lastExpr: ExprSyntax? = nil
            do {
                for item in body {
                    last = try await execute(item: item, in: callScope)
                    lastExpr = expressionOf(item: item)
                }
                if let returnType = fn.returnType, let lastExpr {
                    last = try await coerce(
                        value: last,
                        expr: lastExpr,
                        toType: returnType,
                        in: .returnValue
                    )
                }
            } catch let signal as ReturnSignal {
                last = signal.value
            } catch {
                caught = error
            }
            await runDeferred(in: callScope)
            // Inout writeback: flush each `inout` param's final binding
            // back to the caller's l-value. Runs even on thrown errors —
            // Swift's inout semantics persist mutations performed before
            // the throw. Writeback errors take precedence iff there's no
            // other pending error.
            for (paramIdx, write) in inoutWritebacks {
                guard paramIdx < fn.parameters.count,
                      let binding = callScope.lookup(fn.parameters[paramIdx].name)
                else { continue }
                do {
                    try write(binding.value)
                } catch {
                    if caught == nil { caught = error }
                }
            }
            if let caught { throw caught }
            return last
        }
    }

    /// Recognize `print(items..., separator:, terminator:)` calls and
    /// dispatch with the resolved separator/terminator. Returns nil for
    /// non-`print` calls so the caller can fall through to the regular
    /// builtin dispatcher.
    func tryPrintCall(_ call: FunctionCallExprSyntax, in scope: Scope) async throws -> Value? {
        guard let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
              ref.baseName.text == "print"
        else { return nil }
        // Only fire when the user supplied a `separator:` or `terminator:`
        // label — bare `print(x, y)` already works through the built-in
        // and matches Swift's default-space separator.
        let argSyntaxes = Array(call.arguments)
        let hasNamedTail = argSyntaxes.contains { $0.label?.text == "separator" || $0.label?.text == "terminator" }
        if !hasNamedTail { return nil }
        var items: [Value] = []
        var separator = " "
        var terminator = "\n"
        for arg in argSyntaxes {
            let value = try await evaluate(arg.expression, in: scope)
            switch arg.label?.text {
            case "separator":
                guard case .string(let s) = value else {
                    throw RuntimeError.invalid("print: separator must be String")
                }
                separator = s
            case "terminator":
                guard case .string(let s) = value else {
                    throw RuntimeError.invalid("print: terminator must be String")
                }
                terminator = s
            default:
                items.append(value)
            }
        }
        // Route each item through `describe` so script-defined
        // `description` getters are honored (CustomStringConvertible-
        // style lookup) before falling back to Value's default.
        let parts = try await items.asyncMap { try await describe($0) }
        let body = parts.joined(separator: separator)
        // The default-`output` closure adds its own newline (it wraps
        // `Swift.print` in the binary, "$0 + \n" in tests). When the
        // user's terminator is `\n` we route through `output` so test
        // captures see it. For other terminators we go straight through
        // `Swift.print`'s terminator parameter — same buffering as
        // `output`'s underlying `Swift.print`, so ordering with sibling
        // `print(...)` calls is preserved.
        if terminator == "\n" {
            output(body)
        } else {
            Swift.print(body, terminator: terminator)
        }
        return .void
    }

    /// If a `CodeBlockItem` is just an expression (rather than a decl/stmt),
    /// extract that expression so we can use it for return-value coercion.
    private func expressionOf(item: CodeBlockItemSyntax) -> ExprSyntax? {
        switch item.item {
        case .expr(let expr): return expr
        default: return nil
        }
    }

    /// For a small set of builtin methods we know the expected argument type
    /// up-front. Returning a non-nil type name lets `evaluateArg` resolve
    /// implicit-member access expressions like `.whitespaces` against that
    /// type. Real Swift uses full bidirectional inference; this is a
    /// pragmatic narrow path covering the cases LLMs actually emit.
    /// Companion to `implicitMemberContext` for built-in initializers.
    /// `String(data:encoding: .utf8)` resolves `.utf8` against
    /// `String.Encoding`. Narrow allowlist — full bidirectional inference
    /// is out of scope.
    func implicitContextForInit(typeName: String, label: String) -> String? {
        switch (typeName, label) {
        case ("String", "encoding"): return "String.Encoding"
        default: return nil
        }
    }

    func implicitMemberContext(method: String, receiver: Value) -> String? {
        // `Double.rounded(_:)` takes a `FloatingPointRoundingRule`, an
        // inline-cased method (not registered as an extension), so we
        // resolve `.up`/`.down`/etc. without the registration check.
        if case .double = receiver, method == "rounded" {
            return "FloatingPointRoundingRule"
        }
        // For everything else we gate on the method being actually
        // registered — without that, an implicit-member arg failing to
        // resolve would mask the real "no member 'foo'" diagnostic.
        let recvType = registryTypeName(receiver)
        guard extensionMethod(typeName: recvType, name: method) != nil else {
            return nil
        }
        if case .string = receiver {
            switch method {
            case "trimmingCharacters", "components", "rangeOfCharacter",
                 "addingPercentEncoding":
                return "CharacterSet"
            case "write", "data", "lengthOfBytes", "canBeConverted",
                 "cString", "maximumLengthOfBytes":
                // These take a `String.Encoding` arg (`using:` /
                // `encoding:`). Resolve `.utf8` / `.ascii` / etc.
                return "String.Encoding"
            default: return nil
            }
        }
        return nil
    }

    /// Evaluate a call argument, resolving a bare implicit-member access
    /// (`.whitespaces`) against `contextType` when supplied.
    func evaluateArg(
        _ expr: ExprSyntax,
        label: String?,
        contextType: String?,
        in scope: Scope
    ) async throws -> Value {
        if let contextType,
           let member = expr.as(MemberAccessExprSyntax.self),
           member.base == nil
        {
            return try await lookupStaticMember(
                typeName: contextType,
                member: member.declName.baseName.text,
                at: member.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        return try await evaluate(expr, in: scope)
    }

    /// Attempt a mutating method call on a stored variable (`Bool.toggle`,
    /// `Array.append`, etc.). Returns nil if `methodName` isn't a known
    /// mutating method on the variable's value type, so the caller can
    /// fall through to other dispatch paths.
    ///
    /// Two storage paths are handled:
    ///   1. Direct binding in the current scope (`var a = [1,2]; a.append(3)`).
    ///   2. Implicit-self property in a mutating struct method
    ///      (`mutating func push() { items.append(x) }`) — the mutation
    ///      flows through `self.items` and writes back via the surrounding
    ///      mutating-method call site.
    func tryMutatingMethodCall(
        methodName: String,
        varName: String,
        call: FunctionCallExprSyntax,
        in scope: Scope
    ) async throws -> Value? {
        // Resolve the storage target: either a direct binding or
        // self-property in scope.
        let storage: MutationStorage?
        // Implicit-self precedence: a class field with the same name as an
        // outer-captured var must win, mirroring identifier-read rules.
        let selfOwner = scope.lookupWithOwner("self")
        let nameOwner = scope.lookupWithOwner(varName)
        let preferSelf: Bool = {
            guard let (_, selfScope) = selfOwner else { return false }
            if let (_, owner) = nameOwner {
                return !selfScope.isAncestor(of: owner)
            }
            return true
        }()
        if preferSelf, let (selfBinding, _) = selfOwner {
            if case .classInstance(let inst) = selfBinding.value,
               let idx = inst.fields.firstIndex(where: { $0.name == varName })
            {
                storage = .classProperty(inst: inst, propIndex: idx, current: inst.fields[idx].value)
            } else if case .structValue(_, let fields) = selfBinding.value,
                      let idx = fields.firstIndex(where: { $0.name == varName })
            {
                storage = .selfProperty(scope: scope, propIndex: idx, mutable: selfBinding.mutable, current: fields[idx].value)
            } else if let binding = scope.lookup(varName) {
                storage = .binding(scope: scope, name: varName, mutable: binding.mutable, current: binding.value)
            } else {
                storage = nil
            }
        } else if let binding = scope.lookup(varName) {
            storage = .binding(scope: scope, name: varName, mutable: binding.mutable, current: binding.value)
        } else if let selfBinding = scope.lookup("self") {
            if case .structValue(_, let fields) = selfBinding.value,
               let idx = fields.firstIndex(where: { $0.name == varName })
            {
                storage = .selfProperty(scope: scope, propIndex: idx, mutable: selfBinding.mutable, current: fields[idx].value)
            } else if case .classInstance(let inst) = selfBinding.value,
                      let idx = inst.fields.firstIndex(where: { $0.name == varName })
            {
                storage = .classProperty(inst: inst, propIndex: idx, current: inst.fields[idx].value)
            } else {
                storage = nil
            }
        } else {
            storage = nil
        }
        guard let storage else { return nil }

        let value = storage.current
        switch (value, methodName) {
        case (.bool(let b), "toggle"):
            guard call.arguments.isEmpty, call.trailingClosure == nil else { return nil }
            try storage.requireMutable(varName: varName)
            try storage.write(.bool(!b))
            return .void

        case (.set(var xs), let m) where ["insert", "remove", "formUnion", "formIntersection", "subtract", "formSymmetricDifference"].contains(m):
            try storage.requireMutable(varName: varName)
            let argSyntaxes = Array(call.arguments)
            let args = try await argSyntaxes.asyncMap { try await evaluate($0.expression, in: scope) }
            // Strict element type for `Set<T>`: insert/remove must match.
            let setElementType = scope.lookup(varName)?.declaredType
                .flatMap { $0.as(IdentifierTypeSyntax.self) }
                .flatMap { $0.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self) }
            let result: Value
            switch (m, args.count) {
            case ("insert", 1):
                if let setElementType,
                   !valueMatchesType(args[0], setElementType),
                   !isGenericPlaceholder(setElementType.description.trimmingCharacters(in: .whitespaces))
                {
                    throw RuntimeError.invalid(
                        "cannot convert value of type '\(typeName(args[0]))' to expected argument type '\(setElementType.description.trimmingCharacters(in: .whitespaces))'"
                    )
                }
                if xs.contains(args[0]) {
                    // Real Swift returns `(inserted: Bool, memberAfterInsert: T)`;
                    // we model the most-asked usage (`set.insert(x)` ignored
                    // result) and surface a simple `Bool` for cases where
                    // the user inspects it. Tuple shape would diverge from
                    // Swift's API; settle for the simpler convention here.
                    result = .bool(false)
                } else {
                    xs.append(args[0])
                    result = .bool(true)
                }
            case ("remove", 1):
                if let i = xs.firstIndex(of: args[0]) {
                    let removed = xs.remove(at: i)
                    result = .optional(removed)
                } else {
                    result = .optional(nil)
                }
            case ("formUnion", 1):
                let other = try iterableToArray(args[0])
                for v in other where !xs.contains(v) { xs.append(v) }
                result = .void
            case ("formIntersection", 1):
                let other = try iterableToArray(args[0])
                xs = xs.filter { other.contains($0) }
                result = .void
            case ("subtract", 1):
                let other = try iterableToArray(args[0])
                xs = xs.filter { !other.contains($0) }
                result = .void
            case ("formSymmetricDifference", 1):
                let other = try iterableToArray(args[0])
                let onlyA = xs.filter { !other.contains($0) }
                let onlyB = other.filter { !xs.contains($0) }
                xs = onlyA + onlyB
                result = .void
            default:
                return nil
            }
            try storage.write(.set(xs))
            return result

        case (.dict(var entries), "removeValue"):
            try storage.requireMutable(varName: varName)
            let argSyntaxes = Array(call.arguments)
            guard argSyntaxes.count == 1, argSyntaxes[0].label?.text == "forKey" else {
                return nil
            }
            let key = try await evaluate(argSyntaxes[0].expression, in: scope)
            if let i = entries.firstIndex(where: { $0.key == key }) {
                let removed = entries.remove(at: i).value
                try storage.write(.dict(entries))
                return .optional(removed)
            }
            return .optional(nil)

        case (.array(var arr), "swapAt"):
            try storage.requireMutable(varName: varName)
            let argSyntaxes = Array(call.arguments)
            guard argSyntaxes.count == 2 else {
                throw RuntimeError.invalid("Array.swapAt: expected 2 arguments")
            }
            let i = try await evaluate(argSyntaxes[0].expression, in: scope)
            let j = try await evaluate(argSyntaxes[1].expression, in: scope)
            guard case .int(let ii) = i, case .int(let jj) = j else {
                throw RuntimeError.invalid("Array.swapAt: arguments must be Int")
            }
            guard ii >= 0, ii < arr.count, jj >= 0, jj < arr.count else {
                throw RuntimeError.invalid("Array.swapAt: index out of bounds")
            }
            arr.swapAt(ii, jj)
            try storage.write(.array(arr))
            return .void

        case (.array(var arr), let m) where ["sort", "shuffle", "removeAll", "reverse"].contains(m):
            try storage.requireMutable(varName: varName)
            let argSyntaxes = Array(call.arguments)
            let args = try await argSyntaxes.asyncMap { try await evaluate($0.expression, in: scope) }
            switch (m, args.count) {
            case ("sort", 0):
                arr = try await sortByNaturalOrder(arr)
            case ("sort", 1):
                guard case .function(let fn) = args[0] else {
                    throw RuntimeError.invalid("Array.sort: argument must be a closure")
                }
                arr = try await sortByClosure(arr, comparator: fn)
            case ("shuffle", 0):
                arr.shuffle()
            case ("reverse", 0):
                arr.reverse()
            case ("removeAll", 0):
                arr = []
            case ("removeAll", 1):
                // `removeAll(where: predicate)`.
                guard case .function(let fn) = args[0] else {
                    throw RuntimeError.invalid("Array.removeAll(where:): argument must be a closure")
                }
                var keep: [Value] = []
                for el in arr {
                    let r = try await invoke(fn, args: [el])
                    guard case .bool(let drop) = r else {
                        throw RuntimeError.invalid(
                            "Array.removeAll(where:): closure must return Bool"
                        )
                    }
                    if !drop { keep.append(el) }
                }
                arr = keep
            default:
                return nil
            }
            try storage.write(.array(arr))
            return .void

        case (.array(var arr), let m) where ["append", "removeLast", "removeFirst", "insert", "remove"].contains(m):
            try storage.requireMutable(varName: varName)
            let argSyntaxes = Array(call.arguments)
            let args = try await argSyntaxes.asyncMap { try await evaluate($0.expression, in: scope) }
            let labels = argSyntaxes.map { $0.label?.text }
            let result: Value
            // Element-type strictness: when the binding has a declared
            // `[T]` annotation, mutating-add operations must supply a
            // matching value. Mirrors swiftc's "cannot convert value of
            // type 'X' to expected argument type 'T'".
            let elementType = scope.lookup(varName)?.declaredType
                .flatMap { $0.as(ArrayTypeSyntax.self)?.element }
            switch (m, args.count, labels) {
            case ("append", 1, [nil]):
                if let elementType, !valueMatchesType(args[0], elementType),
                   !isGenericPlaceholder(elementType.description.trimmingCharacters(in: .whitespaces))
                {
                    throw RuntimeError.invalid(
                        "cannot convert value of type '\(typeName(args[0]))' to expected argument type '\(elementType.description.trimmingCharacters(in: .whitespaces))'"
                    )
                }
                arr.append(args[0])
                result = .void
            case ("append", 1, ["contentsOf"]):
                guard case .array(let other) = args[0] else {
                    throw RuntimeError.invalid("Array.append(contentsOf:): argument must be Array")
                }
                arr.append(contentsOf: other)
                result = .void
            case ("removeLast", 0, _):
                guard !arr.isEmpty else { throw RuntimeError.invalid("Array.removeLast: empty array") }
                result = arr.removeLast()
            case ("removeFirst", 0, _):
                guard !arr.isEmpty else { throw RuntimeError.invalid("Array.removeFirst: empty array") }
                result = arr.removeFirst()
            case ("insert", 2, [nil, "at"]):
                guard case .int(let i) = args[1], i >= 0, i <= arr.count else {
                    throw RuntimeError.invalid("Array.insert(_:at:): index out of bounds")
                }
                arr.insert(args[0], at: i)
                result = .void
            case ("remove", 1, ["at"]):
                guard case .int(let i) = args[0], i >= 0, i < arr.count else {
                    throw RuntimeError.invalid("Array.remove(at:): index out of bounds")
                }
                result = arr.remove(at: i)
            default:
                return nil // unrecognized variant — fall through
            }
            try storage.write(.array(arr))
            return result

        default:
            return nil
        }
    }

    /// An lvalue location for a mutating method's result. Either a top-level
    /// binding or a property on the current method's `self`.
    private enum MutationStorage {
        case binding(scope: Scope, name: String, mutable: Bool, current: Value)
        case selfProperty(scope: Scope, propIndex: Int, mutable: Bool, current: Value)
        /// `self.field.append(...)` inside a class method. Class fields
        /// always mutate (no `let`-of-class restriction at the field
        /// level), so we don't carry a mutability flag.
        case classProperty(inst: ClassInstance, propIndex: Int, current: Value)

        var current: Value {
            switch self {
            case .binding(_, _, _, let v): return v
            case .selfProperty(_, _, _, let v): return v
            case .classProperty(_, _, let v): return v
            }
        }

        func requireMutable(varName: String) throws {
            switch self {
            case .binding(_, _, let mut, _):
                if !mut {
                    throw RuntimeError.invalid(
                        "cannot use mutating member on immutable value: '\(varName)' is a 'let' constant"
                    )
                }
            case .selfProperty(_, _, let mut, _):
                if !mut {
                    throw RuntimeError.invalid(
                        "left side of mutating operator isn't mutable: 'self' is immutable"
                    )
                }
            case .classProperty:
                break // always mutable
            }
        }

        func write(_ value: Value) throws {
            switch self {
            case .binding(let scope, let name, _, _):
                _ = scope.assign(name, value: value)
            case .selfProperty(let scope, let idx, _, _):
                guard let selfBinding = scope.lookup("self"),
                      case .structValue(let typeName, var fields) = selfBinding.value
                else {
                    throw RuntimeError.invalid("self lost during mutation")
                }
                fields[idx].value = value
                _ = scope.assign("self", value: .structValue(typeName: typeName, fields: fields))
            case .classProperty(let inst, let idx, _):
                inst.fields[idx].value = value
            }
        }
    }

    /// Handle `[T]()` and `[T](repeating: x, count: n)` initializer-style
    /// calls. We don't enforce that the produced values match `T` — the type
    /// is just a parser-required label here.
    func evaluateTypedArrayInitializer(_ call: FunctionCallExprSyntax, in scope: Scope) async throws -> Value {
        // No args → empty array.
        if call.arguments.isEmpty && call.trailingClosure == nil {
            return .array([])
        }
        // repeating:count:
        let labeledArgs = Array(call.arguments)
        if labeledArgs.count == 2,
           labeledArgs[0].label?.text == "repeating",
           labeledArgs[1].label?.text == "count"
        {
            let element = try await evaluate(labeledArgs[0].expression, in: scope)
            let countValue = try await evaluate(labeledArgs[1].expression, in: scope)
            guard case .int(let n) = countValue, n >= 0 else {
                throw RuntimeError.invalid(
                    "Array initializer 'count:' must be a non-negative Int"
                )
            }
            return .array(Array(repeating: element, count: n))
        }
        throw RuntimeError.invalid(
            "[T] initializer: only `()` and `(repeating:count:)` forms are supported"
        )
    }
}
