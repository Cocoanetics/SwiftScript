import SwiftSyntax

extension Interpreter {
    /// `#name(args…)` — dispatch a freestanding macro expansion to its
    /// registered handler (`bridges["macro #name"]`).
    ///
    /// Every argument reaches the handler both evaluated and as source
    /// text, which is what separates a macro from a function: the
    /// handler for `#expect(a == b)` receives `false` *and* `"a == b"`.
    /// Trailing closures fold into the argument list (`#expect(throws:)
    /// { … }` arrives as two arguments). An unregistered `#name` is a
    /// hard error with stock Swift's wording — silently returning
    /// `.void` would diverge from a compiler that refuses the file.
    func evaluate(
        macroExpansion node: MacroExpansionExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        let name = node.macroName.text
        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard case .macro(let body)? = bridges[bridgeKey(forMacro: name)] else {
            throw RuntimeError.noMacro(name, at: offset)
        }
        guard node.genericArgumentClause == nil else {
            throw RuntimeError.unsupported(
                "generic arguments on macro '#\(name)'",
                at: offset
            )
        }
        var args: [MacroArgument] = []
        for element in node.arguments {
            args.append(MacroArgument(
                label: element.label?.text,
                value: try await evaluateHostArgument(element.expression, in: scope),
                sourceText: element.expression.trimmedDescription
            ))
        }
        if let trailing = node.trailingClosure {
            args.append(MacroArgument(
                label: nil,
                value: try await evaluate(closure: trailing, in: scope),
                sourceText: trailing.trimmedDescription
            ))
            for extra in node.additionalTrailingClosures {
                args.append(MacroArgument(
                    label: extra.label.text,
                    value: try await evaluate(closure: extra.closure, in: scope),
                    sourceText: extra.closure.trimmedDescription
                ))
            }
        }
        return try await callingBridge { try await body(args) }
    }

    /// Loud error for a freestanding macro in *member* position
    /// (`struct S { #foo("x") }`). Member macros declare members —
    /// there is no value-returning handler shape for that — and stock
    /// Swift would expand or refuse the file, never drop the member.
    /// Called from each member walk (struct / class / enum / extension).
    func rejectMacroMember(_ decl: DeclSyntax) throws {
        guard let node = decl.as(MacroExpansionDeclSyntax.self) else { return }
        throw RuntimeError.unsupported(
            "freestanding macro '#\(node.macroName.text)' in member position — macros expand only in expression position",
            at: node.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    /// Record `declarationName` as carrying each host-registered
    /// attribute present in `attributes`. Arguments are evaluated
    /// eagerly, in the declaration's scope, so `declarations(withAttribute:)`
    /// stays a plain synchronous read.
    func recordAttributedDeclarations(
        _ attributes: AttributeListSyntax,
        declarationName: String,
        invocable: Value?,
        in scope: Scope
    ) async throws {
        guard !registeredAttributes.isEmpty else { return }
        for element in attributes {
            guard case .attribute(let attr) = element else { continue }
            let attrName = attr.attributeName.trimmedDescription
            guard registeredAttributes.contains(attrName) else { continue }
            var args: [MacroArgument] = []
            if case .argumentList(let list)? = attr.arguments {
                for arg in list {
                    args.append(MacroArgument(
                        label: arg.label?.text,
                        value: try await evaluateHostArgument(arg.expression, in: scope),
                        sourceText: arg.expression.trimmedDescription
                    ))
                }
            }
            attributedDeclarations.removeAll {
                $0.attribute == attrName && $0.name == declarationName
            }
            attributedDeclarations.append(AttributedDeclaration(
                attribute: attrName,
                name: declarationName,
                arguments: args,
                invocable: invocable
            ))
        }
    }

    /// Evaluate one macro or attribute argument. The parameter types of
    /// a registered macro / attribute exist only on the host, so
    /// implicit-member forms — bare (`.serialized`) and call-shaped
    /// (`.disabled("flaky")`, including nested ones like
    /// `.tags(.critical)`) — become unresolved enum markers
    /// (`typeName: ""`) for the host to interpret, extending issue
    /// #11's defer-to-the-callee rule. Everything else evaluates
    /// normally.
    private func evaluateHostArgument(
        _ expr: ExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        if let member = expr.as(MemberAccessExprSyntax.self), member.base == nil {
            return .enumValue(
                typeName: "",
                caseName: member.declName.baseName.text,
                associatedValues: []
            )
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base == nil
        {
            var payload: [Value] = []
            for arg in call.arguments {
                payload.append(try await evaluateHostArgument(arg.expression, in: scope))
            }
            return .enumValue(
                typeName: "",
                caseName: member.declName.baseName.text,
                associatedValues: payload
            )
        }
        return try await evaluate(expr, in: scope)
    }
}
