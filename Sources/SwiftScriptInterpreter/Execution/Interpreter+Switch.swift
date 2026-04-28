import SwiftSyntax

extension Interpreter {
    func evaluate(switchExpr: SwitchExprSyntax, in scope: Scope) async throws -> Value {
        let subject = try await evaluate(switchExpr.subject, in: scope)
        let cases = Array(switchExpr.cases)

        for (idx, caseSyntax) in cases.enumerated() {
            guard let switchCase = caseSyntax.as(SwitchCaseSyntax.self) else { continue }
            switch switchCase.label {
            case .case(let caseLabel):
                for item in caseLabel.caseItems {
                    guard let bindScope = try await matchPattern(
                        item.pattern,
                        against: subject,
                        in: scope
                    ) else {
                        continue
                    }
                    if let whereClause = item.whereClause {
                        let cond = try await evaluate(whereClause.condition, in: bindScope)
                        guard case .bool(let pass) = cond else {
                            throw RuntimeError.invalid(
                                "switch where: condition must be Bool, got \(typeName(cond))"
                            )
                        }
                        if !pass { continue }
                    }
                    return try await executeWithFallthrough(
                        cases: cases, startingAt: idx,
                        firstScope: bindScope, parent: scope
                    )
                }
            case .default:
                let defaultScope = Scope(parent: scope)
                return try await executeWithFallthrough(
                    cases: cases, startingAt: idx,
                    firstScope: defaultScope, parent: scope
                )
            }
        }
        throw RuntimeError.invalid(
            "no case matched in switch and no `default` clause"
        )
    }

    /// Run the case at `startingAt`, then keep flowing into subsequent
    /// cases as long as the body throws `FallthroughSignal`. The
    /// fallthrough target's pattern is not re-checked — the body runs
    /// in a fresh scope that doesn't see the prior case's bindings,
    /// matching Swift's "fallthrough cannot have variable bindings"
    /// rule.
    private func executeWithFallthrough(
        cases: [SwitchCaseListSyntax.Element],
        startingAt: Int,
        firstScope: Scope,
        parent: Scope
    ) async throws -> Value {
        var idx = startingAt
        var caseScope = firstScope
        var last: Value = .void
        while idx < cases.count {
            guard let switchCase = cases[idx].as(SwitchCaseSyntax.self) else {
                idx += 1; continue
            }
            do {
                last = try await executeCase(switchCase.statements, in: caseScope)
                return last
            } catch is FallthroughSignal {
                idx += 1
                caseScope = Scope(parent: parent)
            }
        }
        return last
    }

    private func executeCase(
        _ items: CodeBlockItemListSyntax,
        in scope: Scope
    ) async throws -> Value {
        var last: Value = .void
        for item in items {
            last = try await execute(item: item, in: scope)
        }
        return last
    }

    /// Public alias so `if case <pat> = <expr>` (handled in
    /// `evaluateConditions`) can reuse the same matcher.
    func matchSwitchPattern(
        _ pattern: PatternSyntax,
        against subject: Value,
        in scope: Scope
    ) async throws -> Scope? {
        return try await matchPattern(pattern, against: subject, in: scope)
    }

    /// Try to match `pattern` against `subject`. On success returns a fresh
    /// scope with any pattern bindings; on failure returns nil. Throws only on
    /// genuinely unsupported pattern kinds.
    private func matchPattern(
        _ pattern: PatternSyntax,
        against subject: Value,
        in scope: Scope
    ) async throws -> Scope? {
        if pattern.is(WildcardPatternSyntax.self) {
            return Scope(parent: scope)
        }
        // Bare identifier inside a `let`-distributed pattern (e.g. the
        // `x` in `let .some(x)`). Bind to the subject.
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            let bindScope = Scope(parent: scope)
            bindScope.bind(ident.identifier.text, value: subject, mutable: false)
            return bindScope
        }
        if let exprPattern = pattern.as(ExpressionPatternSyntax.self) {
            // Tuple pattern: `case (0, _):`, `case (_, 1):`, etc.
            // Matches element-wise; each element can be a literal,
            // wildcard (`_`), or nested pattern.
            if let tupleExpr = exprPattern.expression.as(TupleExprSyntax.self),
               case .tuple(let subjectElements, _) = subject,
               tupleExpr.elements.count == subjectElements.count
            {
                let bindScope = Scope(parent: scope)
                for (elementSyntax, subjectValue) in zip(tupleExpr.elements, subjectElements) {
                    let elExpr = elementSyntax.expression
                    // `_` parses as DiscardAssignmentExprSyntax — wildcard.
                    if elExpr.is(DiscardAssignmentExprSyntax.self) { continue }
                    // Nested pattern (e.g. `let x` inside the tuple).
                    if let patExpr = elExpr.as(PatternExprSyntax.self) {
                        guard let inner = try await matchPattern(
                            patExpr.pattern, against: subjectValue, in: bindScope
                        ) else { return nil }
                        inner.copyBindings(into: bindScope)
                        continue
                    }
                    // `.some(let a)` / `.none` / `.enumCase(let x)` —
                    // implicit-member-access patterns appearing as tuple
                    // elements. Delegate to the optional/enum matchers.
                    if isImplicitEnumPattern(elExpr) {
                        if case .optional(let inner) = subjectValue {
                            guard let result = try await matchOptionalPattern(
                                elExpr, inner: inner, in: scope, isLet: true
                            ) else { return nil }
                            result.copyBindings(into: bindScope)
                            continue
                        }
                        if case .enumValue(let typeName, let subjectCase, let subjectValues) = subjectValue {
                            guard let result = try await matchEnumPattern(
                                elExpr,
                                typeName: typeName,
                                subjectCase: subjectCase,
                                subjectValues: subjectValues,
                                in: scope
                            ) else { return nil }
                            result.copyBindings(into: bindScope)
                            continue
                        }
                    }
                    // Literal — compare for equality.
                    let patternValue = try await evaluate(elExpr, in: scope)
                    if patternValue != subjectValue { return nil }
                }
                return bindScope
            }
            // Enum patterns: `case .red:` and `case .ok(let n):` use
            // implicit-member access against the subject's enum type.
            // When the pattern *looks* like an enum pattern, require a
            // successful match (don't fall through to literal-equality).
            if case .enumValue(let typeName, let subjectCase, let subjectValues) = subject,
               isImplicitEnumPattern(exprPattern.expression)
            {
                return try await matchEnumPattern(
                    exprPattern.expression,
                    typeName: typeName,
                    subjectCase: subjectCase,
                    subjectValues: subjectValues,
                    in: scope
                )
            }
            // `.some(let v)` / `.none` against an `.optional` subject —
            // route to the dedicated optional matcher.
            if case .optional(let inner) = subject,
               isImplicitEnumPattern(exprPattern.expression)
            {
                return try await matchOptionalPattern(
                    exprPattern.expression,
                    inner: inner,
                    in: scope,
                    isLet: true
                )
            }
            // `case 1:`, `case 1...10:`, `case "foo":`, …
            // For ranges, use Range.contains semantics; otherwise compare ==.
            let patternValue = try await evaluate(exprPattern.expression, in: scope)
            if case .range(let lo, let hi, let closed) = patternValue,
               case .int(let i) = subject {
                let inRange = closed ? (i >= lo && i <= hi) : (i >= lo && i < hi)
                return inRange ? Scope(parent: scope) : nil
            }
            return patternValue == subject ? Scope(parent: scope) : nil
        }
        // `case let (a, b):` / `case let (a, b) where …` — value-binding
        // wrapping a tuple. SwiftSyntax parses this as ValueBinding →
        // ExpressionPattern → TupleExpr (the `let` distributes into the
        // tuple's identifier subexpressions). Each subexpression is a
        // bare DeclReference (`a`), a wildcard (`_`), or a literal.
        if let valueBinding = pattern.as(ValueBindingPatternSyntax.self),
           let exprPat = valueBinding.pattern.as(ExpressionPatternSyntax.self),
           let tupleExpr = exprPat.expression.as(TupleExprSyntax.self),
           case .tuple(let subjectElements, _) = subject,
           tupleExpr.elements.count == subjectElements.count
        {
            let bindScope = Scope(parent: scope)
            let isLet = valueBinding.bindingSpecifier.tokenKind == .keyword(.let)
            for (elementSyntax, subjectValue) in zip(tupleExpr.elements, subjectElements) {
                let elExpr = elementSyntax.expression
                if elExpr.is(DiscardAssignmentExprSyntax.self) { continue }
                if let ref = elExpr.as(DeclReferenceExprSyntax.self) {
                    bindScope.bind(
                        ref.baseName.text,
                        value: subjectValue,
                        mutable: !isLet
                    )
                    continue
                }
                // `let (a, b)` distributes the binding into the tuple,
                // so each element parses as PatternExpr → IdentifierPat.
                if let patExpr = elExpr.as(PatternExprSyntax.self),
                   let ident = patExpr.pattern.as(IdentifierPatternSyntax.self)
                {
                    bindScope.bind(
                        ident.identifier.text,
                        value: subjectValue,
                        mutable: !isLet
                    )
                    continue
                }
                if let patExpr = elExpr.as(PatternExprSyntax.self),
                   patExpr.pattern.is(WildcardPatternSyntax.self)
                {
                    continue
                }
                // Literal element — value must match.
                let patternValue = try await evaluate(elExpr, in: scope)
                if patternValue != subjectValue { return nil }
            }
            return bindScope
        }
        if let valueBinding = pattern.as(ValueBindingPatternSyntax.self) {
            let bindScope = Scope(parent: scope)
            let isLet = valueBinding.bindingSpecifier.tokenKind == .keyword(.let)
            if let identPattern = valueBinding.pattern.as(IdentifierPatternSyntax.self) {
                bindScope.bind(
                    identPattern.identifier.text,
                    value: subject,
                    mutable: !isLet
                )
                return bindScope
            }
            if valueBinding.pattern.is(WildcardPatternSyntax.self) {
                return bindScope
            }
            // Sub-pattern wrapped in an ExpressionPatternSyntax — covers
            // optional shorthand (`let x?`), explicit `.some(x)` / `.none`,
            // and the type-cast pattern (`let i as Int`).
            if let exprPat = valueBinding.pattern.as(ExpressionPatternSyntax.self) {
                let inner = exprPat.expression
                // `let i as Int` — type-cast pattern. Bind only if the
                // subject's runtime type matches the cast type. The inner
                // binding-name expression is either a bare DeclReference
                // (`i`) or a PatternExpr wrapping an IdentifierPattern
                // (depending on parsing context).
                if let asExpr = inner.as(AsExprSyntax.self) {
                    let bindName: String? = {
                        if let ref = asExpr.expression.as(DeclReferenceExprSyntax.self) {
                            return ref.baseName.text
                        }
                        if let patExpr = asExpr.expression.as(PatternExprSyntax.self),
                           let ident = patExpr.pattern.as(IdentifierPatternSyntax.self)
                        {
                            return ident.identifier.text
                        }
                        return nil
                    }()
                    if let bindName {
                        let castType = asExpr.type
                        let isOptional = asExpr.questionOrExclamationMark?.tokenKind == .postfixQuestionMark
                        if isOptional {
                            let bound: Value = valueMatchesType(subject, castType)
                                ? .optional(subject)
                                : .optional(nil)
                            bindScope.bind(bindName, value: bound, mutable: !isLet)
                            return bindScope
                        }
                        guard valueMatchesType(subject, castType) else { return nil }
                        bindScope.bind(bindName, value: subject, mutable: !isLet)
                        return bindScope
                    }
                }
                // `let x?` — sugar for `let .some(x)`. Subject must be
                // an `.optional`.
                if let chain = inner.as(OptionalChainingExprSyntax.self),
                   case .optional(let innerOpt) = subject
                {
                    guard let unwrapped = innerOpt else { return nil }
                    if let ref = chain.expression.as(DeclReferenceExprSyntax.self) {
                        bindScope.bind(
                            ref.baseName.text, value: unwrapped, mutable: !isLet
                        )
                        return bindScope
                    }
                    if let pat = chain.expression.as(PatternExprSyntax.self) {
                        guard let nested = try await matchPattern(
                            pat.pattern, against: unwrapped, in: bindScope
                        ) else { return nil }
                        nested.copyBindings(into: bindScope)
                        return bindScope
                    }
                    return nil
                }
                // `let .some(x) = opt` — explicit Optional pattern.
                if case .optional(let inner) = subject {
                    if let result = try await matchOptionalPattern(
                        exprPat.expression,
                        inner: inner,
                        in: scope,
                        isLet: isLet
                    ) {
                        return result
                    }
                    return nil
                }
                // `let .foo(x) = enumValue` — let-distributed enum pattern.
                if case .enumValue(let typeName, let subjectCase, let subjectValues) = subject,
                   isImplicitEnumPattern(exprPat.expression)
                {
                    return try await matchEnumPattern(
                        exprPat.expression,
                        typeName: typeName,
                        subjectCase: subjectCase,
                        subjectValues: subjectValues,
                        in: scope
                    )
                }
            }
            // Diagnostic info: include the inner expression's node type
            // so further gaps surface clearly during probing.
            if let exprPat = valueBinding.pattern.as(ExpressionPatternSyntax.self) {
                throw RuntimeError.unsupported(
                    "value-binding pattern with inner \(exprPat.expression.syntaxNodeType)",
                    at: valueBinding.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            }
            throw RuntimeError.unsupported(
                "value-binding pattern with sub-pattern \(valueBinding.pattern.syntaxNodeType)",
                at: valueBinding.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        // `case is Int:` — bare type-check pattern.
        if let isPattern = pattern.as(IsTypePatternSyntax.self) {
            return valueMatchesType(subject, isPattern.type)
                ? Scope(parent: scope) : nil
        }
        // `case let i as Int:` may also parse as ExpressionPattern at the
        // top level (without an enclosing ValueBinding) — handle the
        // direct AsExpr shape too.
        if let exprPat = pattern.as(ExpressionPatternSyntax.self),
           let asExpr = exprPat.expression.as(AsExprSyntax.self),
           asExpr.expression.is(DiscardAssignmentExprSyntax.self)
        {
            // `_ as Int` (rare) — type-only check.
            return valueMatchesType(subject, asExpr.type)
                ? Scope(parent: scope) : nil
        }
        throw RuntimeError.unsupported(
            "pattern \(pattern.syntaxNodeType)",
            at: pattern.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    /// Match an Optional-shaped pattern: `.some(let x)` / `.some(_)` /
    /// `.none`. Returns nil if the pattern doesn't match.
    private func matchOptionalPattern(
        _ expr: ExprSyntax,
        inner: Value?,
        in scope: Scope,
        isLet: Bool
    ) async throws -> Scope? {
        // `.none` — matches when inner is nil.
        if let memberAccess = expr.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil
        {
            let caseName = memberAccess.declName.baseName.text
            if caseName == "none" { return inner == nil ? Scope(parent: scope) : nil }
            if caseName == "some", inner != nil { return Scope(parent: scope) }
            return nil
        }
        // `.some(<sub>)` — match-with-payload.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil,
           memberAccess.declName.baseName.text == "some",
           let value = inner,
           call.arguments.count == 1
        {
            let bindScope = Scope(parent: scope)
            let arg = call.arguments.first!
            if let patExpr = arg.expression.as(PatternExprSyntax.self) {
                guard let inner = try await matchSwitchPattern(
                    patExpr.pattern, against: value, in: bindScope
                ) else { return nil }
                inner.copyBindings(into: bindScope)
                return bindScope
            }
            // Bare identifier acting as a binding — `let .some(x)` after
            // distribution has the inner element parsed as a DeclReference.
            if let ref = arg.expression.as(DeclReferenceExprSyntax.self) {
                bindScope.bind(ref.baseName.text, value: value, mutable: !isLet)
                return bindScope
            }
            // Literal — compare for equality.
            let lit = try await evaluate(arg.expression, in: scope)
            return lit == value ? bindScope : nil
        }
        return nil
    }

    /// True if `expr` is shaped like `.case` or `.case(args)` — i.e., a
    /// member access with no base, possibly wrapped in a call.
    private func isImplicitEnumPattern(_ expr: ExprSyntax) -> Bool {
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return memberAccess.base == nil
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self)
        {
            return memberAccess.base == nil
        }
        return false
    }

    /// Try to match an enum pattern. Handles two shapes:
    ///   - `.red`              → MemberAccess (no base)
    ///   - `.ok(let n)`        → FunctionCall(MemberAccess(no base), [pattern args])
    /// Returns nil if the pattern doesn't fit (so the caller can fall
    /// through to literal-equality matching).
    private func matchEnumPattern(
        _ expr: ExprSyntax,
        typeName: String,
        subjectCase: String,
        subjectValues: [Value],
        in scope: Scope
    ) async throws -> Scope? {
        // Bare case: `.red`
        if let memberAccess = expr.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil
        {
            let patternCase = memberAccess.declName.baseName.text
            return subjectCase == patternCase ? Scope(parent: scope) : nil
        }
        // Case with payload pattern: `.ok(let n)` / `.ok(_)`
        if let call = expr.as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.base == nil
        {
            let patternCase = memberAccess.declName.baseName.text
            guard subjectCase == patternCase else { return nil }
            let argList = Array(call.arguments)
            guard argList.count == subjectValues.count else { return nil }
            let bindScope = Scope(parent: scope)
            for (argSyntax, subjectValue) in zip(argList, subjectValues) {
                // Each pattern arg is an expression in source. SwiftSyntax
                // wraps real patterns (`let n`) inside a PatternExprSyntax.
                if let patExpr = argSyntax.expression.as(PatternExprSyntax.self) {
                    guard let inner = try await matchPattern(
                        patExpr.pattern, against: subjectValue, in: bindScope
                    ) else { return nil }
                    // Promote any bindings into our bindScope.
                    inner.copyBindings(into: bindScope)
                    continue
                }
                // Literal expression — compare for equality.
                let patternValue = try await evaluate(argSyntax.expression, in: scope)
                if patternValue != subjectValue { return nil }
            }
            return bindScope
        }
        return nil
    }
}
