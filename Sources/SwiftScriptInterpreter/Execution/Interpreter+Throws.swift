import SwiftSyntax

extension Interpreter {
    /// `throw expr` — evaluate the expression and raise it as a user error.
    func execute(throw throwStmt: ThrowStmtSyntax, in scope: Scope) async throws -> Value {
        let value = try await evaluate(throwStmt.expression, in: scope)
        throw UserThrowSignal(value: value)
    }

    /// `do { … } catch <pattern> { … } …` — run the body, dispatch any
    /// thrown user error to the first matching catch clause.
    func execute(do doStmt: DoStmtSyntax, in scope: Scope) async throws -> Value {
        do {
            return try await executeBlock(doStmt.body, in: scope)
        } catch let signal as UserThrowSignal {
            // Try each catch clause in order.
            for catchClause in doStmt.catchClauses {
                if let bindScope = try await matchCatchClause(
                    catchClause, value: signal.value, in: scope
                ) {
                    return try await executeBlock(catchClause.body, in: bindScope)
                }
            }
            // No matching catch — re-raise.
            throw signal
        }
    }

    /// Evaluate a `try`/`try?`/`try!` expression. The inner expression is
    /// evaluated; the modifier decides how thrown errors are surfaced.
    func evaluate(try tryExpr: TryExprSyntax, in scope: Scope) async throws -> Value {
        let mark = tryExpr.questionOrExclamationMark?.text
        do {
            return try await evaluate(tryExpr.expression, in: scope)
        } catch let signal as UserThrowSignal {
            switch mark {
            case "?":
                return .optional(nil)
            case "!":
                throw RuntimeError.invalid(
                    "'try!' expression unexpectedly raised an error: \(signal.value.description)"
                )
            default:
                throw signal
            }
        }
    }

    /// Try a catch clause against a thrown value. Returns a Scope with any
    /// bindings if the clause matches, nil if it doesn't.
    private func matchCatchClause(
        _ clause: CatchClauseSyntax,
        value: Value,
        in scope: Scope
    ) async throws -> Scope? {
        let items = Array(clause.catchItems)
        if items.isEmpty {
            // Default catch: implicit `error` binding to the thrown value.
            let bindScope = Scope(parent: scope)
            bindScope.bind("error", value: value, mutable: false)
            return bindScope
        }
        for item in items {
            // A catch item can have a pattern, a where-clause, or both.
            // We just match the pattern; where-clauses are evaluated in
            // the resulting bindScope.
            guard let pattern = item.pattern else {
                let bindScope = Scope(parent: scope)
                bindScope.bind("error", value: value, mutable: false)
                return bindScope
            }
            if let bindScope = try await matchCatchPattern(pattern, against: value, in: scope) {
                if let whereClause = item.whereClause {
                    let cond = try await evaluate(whereClause.condition, in: bindScope)
                    guard case .bool(let pass) = cond else {
                        throw RuntimeError.invalid(
                            "catch where: condition must be Bool, got \(typeName(cond))"
                        )
                    }
                    if !pass { continue }
                }
                return bindScope
            }
        }
        return nil
    }

    /// Catch patterns are like switch patterns but the implicit subject
    /// type is the thrown value. Full-path enum cases (`E.bad`) and
    /// payload patterns (`E.parse(let m)`) must work.
    private func matchCatchPattern(
        _ pattern: PatternSyntax,
        against value: Value,
        in scope: Scope
    ) async throws -> Scope? {
        if pattern.is(WildcardPatternSyntax.self) {
            return Scope(parent: scope)
        }
        if let exprPattern = pattern.as(ExpressionPatternSyntax.self) {
            // Enum-shaped pattern (full path or implicit member).
            if case .enumValue(_, let valueCase, let valueArgs) = value {
                if let bindScope = try await matchEnumPatternForCatch(
                    exprPattern.expression,
                    subjectCase: valueCase,
                    subjectValues: valueArgs,
                    in: scope
                ) {
                    return bindScope
                }
            }
            // Otherwise compare for equality.
            let patternValue = try await evaluate(exprPattern.expression, in: scope)
            return patternValue == value ? Scope(parent: scope) : nil
        }
        if let valueBinding = pattern.as(ValueBindingPatternSyntax.self),
           let ident = valueBinding.pattern.as(IdentifierPatternSyntax.self)
        {
            let bindScope = Scope(parent: scope)
            bindScope.bind(ident.identifier.text, value: value, mutable: false)
            return bindScope
        }
        return nil
    }

    /// Like `matchEnumPattern` for switch but accepts both implicit
    /// (`.bad`) and full-path (`E.bad`) forms.
    private func matchEnumPatternForCatch(
        _ expr: ExprSyntax,
        subjectCase: String,
        subjectValues: [Value],
        in scope: Scope
    ) async throws -> Scope? {
        // Bare or full-path: `.bad`, `E.bad`.
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            let patternCase = memberAccess.declName.baseName.text
            return subjectCase == patternCase ? Scope(parent: scope) : nil
        }
        // Payload form: `.bad(let m)`, `E.bad(let m)`.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self)
        {
            let patternCase = memberAccess.declName.baseName.text
            guard subjectCase == patternCase else { return nil }
            let argList = Array(call.arguments)
            guard argList.count == subjectValues.count else { return nil }
            let bindScope = Scope(parent: scope)
            for (argSyntax, subjectValue) in zip(argList, subjectValues) {
                if let patExpr = argSyntax.expression.as(PatternExprSyntax.self) {
                    if let inner = try await matchCatchPattern(
                        patExpr.pattern, against: subjectValue, in: bindScope
                    ) {
                        inner.copyBindings(into: bindScope)
                        continue
                    }
                    return nil
                }
                let patternValue = try await evaluate(argSyntax.expression, in: scope)
                if patternValue != subjectValue { return nil }
            }
            return bindScope
        }
        return nil
    }
}
