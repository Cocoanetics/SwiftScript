import SwiftSyntax
import Foundation

/// True if the type is `inout T` — wrapped as `AttributedTypeSyntax`
/// with an `inout` specifier. Used by funcDecl/initDecl/methodDecl param
/// parsing to surface the inout flag without tying every site to the
/// specific syntax-tree shape.
func paramIsInout(_ type: TypeSyntax) -> Bool {
    guard let attributed = type.as(AttributedTypeSyntax.self) else { return false }
    return attributed.specifiers.contains { spec in
        if let simple = spec.as(SimpleTypeSpecifierSyntax.self) {
            return simple.specifier.tokenKind == .keyword(.inout)
        }
        return false
    }
}

extension Interpreter {
    func execute(item: CodeBlockItemSyntax, in scope: Scope) async throws -> Value {
        switch item.item {
        case .decl(let decl):
            return try await execute(decl: decl, in: scope)
        case .stmt(let stmt):
            return try await execute(stmt: stmt, in: scope)
        case .expr(let expr):
            return try await evaluate(expr, in: scope)
        }
    }

    private func execute(decl: DeclSyntax, in scope: Scope) async throws -> Value {
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            return try await execute(varDecl: varDecl, in: scope)
        }
        if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            return try await execute(funcDecl: funcDecl, in: scope)
        }
        if let structDecl = decl.as(StructDeclSyntax.self) {
            return try await execute(structDecl: structDecl, in: scope)
        }
        if let classDecl = decl.as(ClassDeclSyntax.self) {
            return try await execute(classDecl: classDecl, in: scope)
        }
        if let actorDecl = decl.as(ActorDeclSyntax.self) {
            return try await execute(actorDecl: actorDecl, in: scope)
        }
        if let enumDecl = decl.as(EnumDeclSyntax.self) {
            return try await execute(enumDecl: enumDecl, in: scope)
        }
        if let extensionDecl = decl.as(ExtensionDeclSyntax.self) {
            return try await execute(extensionDecl: extensionDecl, in: scope)
        }
        if let typeAliasDecl = decl.as(TypeAliasDeclSyntax.self) {
            return try await execute(typeAliasDecl: typeAliasDecl, in: scope)
        }
        // `protocol P { … }` — record the type name so annotations like
        // `var g: P` / `[P]` validate. Conformance is duck-typed; the
        // body's signature requirements aren't enforced.
        if let proto = decl.as(ProtocolDeclSyntax.self) {
            declaredProtocols.insert(proto.name.text)
            return .void
        }
        // `precedencegroup …` / `infix operator … : Group` — folded into
        // the OperatorTable at parse time so SwiftOperators can produce
        // an InfixOperatorExpr with correct associativity. Nothing to do
        // at runtime; the runtime dispatches to a user-declared `func +/<>`
        // when the operator isn't one of the built-ins.
        if decl.is(PrecedenceGroupDeclSyntax.self)
            || decl.is(OperatorDeclSyntax.self)
        {
            return .void
        }
        // `import X` — record the imported module so any `BuiltinModule`
        // registered via `registerOnImport` activates. This is what makes
        // Foundation-side helpers (`sqrt`, `FileManager`, …) gate on the
        // import the way `swiftc` requires.
        if let importDecl = decl.as(ImportDeclSyntax.self) {
            if let firstSegment = importDecl.path.first {
                processImport(firstSegment.name.text)
            }
            return .void
        }
        throw RuntimeError.unsupported(
            "declaration \(decl.syntaxNodeType)",
            at: decl.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    private func execute(varDecl: VariableDeclSyntax, in scope: Scope) async throws -> Value {
        let mutable = varDecl.bindingSpecifier.tokenKind == .keyword(.var)
        for binding in varDecl.bindings {
            // `let _ = expr` — evaluate for its side effects, discard.
            if binding.pattern.is(WildcardPatternSyntax.self) {
                if let initializer = binding.initializer {
                    _ = try await evaluate(initializer.value, in: scope)
                }
                continue
            }
            // Tuple destructuring: `let (x, y) = expr`.
            if let tuplePat = binding.pattern.as(TuplePatternSyntax.self) {
                guard let initializer = binding.initializer else {
                    throw RuntimeError.invalid(
                        "tuple-pattern binding requires an initializer"
                    )
                }
                let value = try await evaluate(initializer.value, in: scope)
                guard case .tuple(let elements, _) = value else {
                    throw RuntimeError.invalid(
                        "cannot destructure non-tuple value (got \(typeName(value)))"
                    )
                }
                let patterns = Array(tuplePat.elements)
                guard patterns.count == elements.count else {
                    throw RuntimeError.invalid(
                        "tuple pattern has \(patterns.count) element(s), value has \(elements.count)"
                    )
                }
                for (subPat, subVal) in zip(patterns, elements) {
                    if subPat.pattern.is(WildcardPatternSyntax.self) {
                        continue
                    }
                    guard let ident = subPat.pattern.as(IdentifierPatternSyntax.self) else {
                        throw RuntimeError.unsupported(
                            "nested tuple pattern \(subPat.pattern.syntaxNodeType)",
                            at: subPat.positionAfterSkippingLeadingTrivia.utf8Offset
                        )
                    }
                    scope.bind(ident.identifier.text, value: subVal, mutable: mutable)
                }
                continue
            }

            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw RuntimeError.unsupported(
                    "non-identifier binding pattern",
                    at: binding.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            }
            let name = pattern.identifier.text
            guard let initializer = binding.initializer else {
                throw RuntimeError.invalid(
                    "binding '\(name)' must have an initializer (uninitialized declarations not yet supported)"
                )
            }
            // Type-existence check on the annotation, if present. Fires
            // before evaluation so `let x: Foo = expensive()` errors at
            // the binding rather than evaluating the RHS for nothing.
            if let typeAnnotation = binding.typeAnnotation {
                try validateType(typeAnnotation.type)
            }
            var value = try await evaluate(
                initializer.value,
                expecting: binding.typeAnnotation?.type,
                in: scope
            )
            // Heterogeneous-array literal without `[Any]` annotation —
            // swiftc rejects with a specific message; we mirror it.
            // Int/Double mixes are accepted (Swift unifies to Double).
            if binding.typeAnnotation == nil,
               initializer.value.is(ArrayExprSyntax.self),
               case .array(let elements) = value,
               elements.count >= 2
            {
                var distinct: Set<String> = []
                for el in elements {
                    var tn = typeName(el)
                    if tn == "Int" { tn = "Double" }
                    distinct.insert(tn)
                }
                if distinct.count > 1 {
                    throw RuntimeError.invalid(
                        "heterogeneous collection literal could only be inferred to '[Any]'; add explicit type annotation if this is intentional"
                    )
                }
            }
            if let typeAnnotation = binding.typeAnnotation {
                value = try await coerce(
                    value: value,
                    expr: initializer.value,
                    toType: typeAnnotation.type,
                    in: .binding
                )
            }
            scope.bind(name, value: value, mutable: mutable, declaredType: binding.typeAnnotation?.type)
        }
        return .void
    }

    private func execute(funcDecl: FunctionDeclSyntax, in scope: Scope) async throws -> Value {
        let name = funcDecl.name.text
        guard let body = funcDecl.body else {
            throw RuntimeError.invalid("function '\(name)' has no body")
        }
        // Push generic parameters into the type-validator scope so
        // references to them inside the param/return types validate.
        let funcGenerics = funcDecl.genericParameterClause?.parameters
            .map { $0.name.text }
            .reduce(into: Set<String>()) { $0.insert($1) } ?? []
        if !funcGenerics.isEmpty {
            genericTypeParameters.append(funcGenerics)
        }
        defer {
            if !funcGenerics.isEmpty { genericTypeParameters.removeLast() }
        }
        let params = try funcDecl.signature.parameterClause.parameters.map { p -> Function.Parameter in
            let firstName = p.firstName.text
            let label = (firstName == "_") ? nil : firstName
            let internalName = (p.secondName?.text) ?? firstName
            try validateType(p.type)
            return Function.Parameter(
                label: label,
                name: internalName,
                type: p.type,
                isVariadic: p.ellipsis != nil,
                defaultValue: p.defaultValue?.value,
                isInout: paramIsInout(p.type)
            )
        }
        if let returnType = funcDecl.signature.returnClause?.type {
            try validateType(returnType)
        }
        let function = Function(
            name: name,
            parameters: params,
            returnType: funcDecl.signature.returnClause?.type,
            genericParameters: Array(funcGenerics),
            kind: .user(body: body.statements, capturedScope: scope)
        )
        scope.bind(name, value: .function(function), mutable: false)
        return .void
    }

    private func execute(stmt: StmtSyntax, in scope: Scope) async throws -> Value {
        if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            var value: Value = .void
            if let returnExpr = returnStmt.expression {
                let expected = returnTypeStack.last ?? nil
                value = try await evaluate(returnExpr, expecting: expected, in: scope)
                if let returnType = expected {
                    value = try await coerce(
                        value: value,
                        expr: returnExpr,
                        toType: returnType,
                        in: .returnValue
                    )
                }
            }
            throw ReturnSignal(value: value)
        }
        if let breakStmt = stmt.as(BreakStmtSyntax.self) {
            throw BreakSignal(label: breakStmt.label?.text)
        }
        if let contStmt = stmt.as(ContinueStmtSyntax.self) {
            throw ContinueSignal(label: contStmt.label?.text)
        }
        if stmt.is(FallThroughStmtSyntax.self) {
            throw FallthroughSignal()
        }
        if let whileStmt = stmt.as(WhileStmtSyntax.self) {
            return try await execute(while: whileStmt, in: scope)
        }
        if let forStmt = stmt.as(ForStmtSyntax.self) {
            return try await execute(forIn: forStmt, in: scope)
        }
        if let repeatStmt = stmt.as(RepeatStmtSyntax.self) {
            return try await execute(repeat: repeatStmt, in: scope)
        }
        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            return try await execute(guard: guardStmt, in: scope)
        }
        if let labeled = stmt.as(LabeledStmtSyntax.self) {
            return try await execute(labeled: labeled, in: scope)
        }
        if let throwStmt = stmt.as(ThrowStmtSyntax.self) {
            return try await execute(throw: throwStmt, in: scope)
        }
        if let doStmt = stmt.as(DoStmtSyntax.self) {
            return try await execute(do: doStmt, in: scope)
        }
        if let deferStmt = stmt.as(DeferStmtSyntax.self) {
            // Register the body to run in reverse order when this scope
            // exits (whether normally, via return, or via thrown error).
            scope.deferred.append(deferStmt.body)
            return .void
        }
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            return try await evaluate(exprStmt.expression, in: scope)
        }
        throw RuntimeError.unsupported(
            "statement \(stmt.syntaxNodeType)",
            at: stmt.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    private func execute(labeled: LabeledStmtSyntax, in scope: Scope) async throws -> Value {
        let label = labeled.label.text
        let inner = labeled.statement
        if let whileStmt = inner.as(WhileStmtSyntax.self) {
            return try await execute(while: whileStmt, label: label, in: scope)
        }
        if let forStmt = inner.as(ForStmtSyntax.self) {
            return try await execute(forIn: forStmt, label: label, in: scope)
        }
        if let repeatStmt = inner.as(RepeatStmtSyntax.self) {
            return try await execute(repeat: repeatStmt, label: label, in: scope)
        }
        throw RuntimeError.unsupported(
            "labeled \(inner.syntaxNodeType)",
            at: inner.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }
}
