import SwiftSyntax

extension Interpreter {
    /// Walk the calledExpression / base path of `expr` looking for an
    /// `OptionalChainingExprSyntax`. If we find one, the whole expression
    /// must be evaluated in chain mode so a nil at any step short-circuits.
    func startsOptionalChain(_ expr: ExprSyntax) -> Bool {
        var current: ExprSyntax? = expr
        while let e = current {
            if e.is(OptionalChainingExprSyntax.self) { return true }
            if let m = e.as(MemberAccessExprSyntax.self) {
                current = m.base
            } else if let f = e.as(FunctionCallExprSyntax.self) {
                current = f.calledExpression
            } else if let s = e.as(SubscriptCallExprSyntax.self) {
                current = s.calledExpression
            } else {
                return false
            }
        }
        return false
    }

    /// Entry point for evaluating a chain. The result is always wrapped in
    /// `.optional`, with `.optional(nil)` if any link in the chain was nil.
    func evaluateInOptionalChain(_ expr: ExprSyntax, in scope: Scope) async throws -> Value {
        switch try await evaluateAsChain(expr, in: scope) {
        case .alive(let v): return .optional(v)
        case .dead:         return .optional(nil)
        }
    }

    /// Internal chain state — `.alive(unwrappedValue)` while every Optional
    /// in the chain has been `.some`, `.dead` once any link returns nil.
    enum ChainState {
        case alive(Value)
        case dead
    }

    /// Walk the chain, evaluating each link and unwrapping Optionals
    /// transparently so the chain "flattens" — `x?.first?.uppercased()` yields
    /// a single Optional, not Optional<Optional<…>>.
    func evaluateAsChain(_ expr: ExprSyntax, in scope: Scope) async throws -> ChainState {
        if let chain = expr.as(OptionalChainingExprSyntax.self) {
            let inner = try await evaluateAsChain(chain.expression, in: scope)
            guard case .alive(let v) = inner else { return .dead }
            // `?` unwraps an Optional; if applied to a non-Optional, treat it
            // as already-alive (Swift would reject this at compile time, but
            // we'd rather accept it than throw at runtime).
            guard case .optional(let opt) = v else { return .alive(v) }
            guard let unwrapped = opt else { return .dead }
            return .alive(unwrapped)
        }
        if let m = expr.as(MemberAccessExprSyntax.self), let base = m.base {
            let baseState = try await evaluateAsChain(base, in: scope)
            guard case .alive(let baseVal) = baseState else { return .dead }
            let result = try await lookupProperty(
                m.declName.baseName.text,
                on: baseVal,
                at: m.positionAfterSkippingLeadingTrivia.utf8Offset
            )
            return absorb(result)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let mAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = mAccess.base
        {
            let baseState = try await evaluateAsChain(base, in: scope)
            guard case .alive(let baseVal) = baseState else { return .dead }
            let args = try await call.arguments.asyncMap { try await evaluate($0.expression, in: scope) }
            let result = try await invokeMethod(
                mAccess.declName.baseName.text,
                on: baseVal,
                args: args,
                at: call.positionAfterSkippingLeadingTrivia.utf8Offset
            )
            return absorb(result)
        }
        if let sub = expr.as(SubscriptCallExprSyntax.self) {
            let baseState = try await evaluateAsChain(sub.calledExpression, in: scope)
            guard case .alive(let baseVal) = baseState else { return .dead }
            let args = try await sub.arguments.asyncMap { try await evaluate($0.expression, in: scope) }
            let result = try await doSubscriptInChain(receiver: baseVal, args: args)
            return absorb(result)
        }
        // Leaf of the chain — evaluate as a normal expression.
        let v = try await evaluate(expr, in: scope)
        return .alive(v)
    }

    /// If a chain link returned an Optional (e.g. `arr.first` is `Element?`),
    /// flatten one level so the chain semantics stay single-Optional.
    private func absorb(_ value: Value) -> ChainState {
        if case .optional(let inner) = value {
            guard let unwrapped = inner else { return .dead }
            return .alive(unwrapped)
        }
        return .alive(value)
    }

    /// Subscript evaluation duplicated for the chain walker because the
    /// non-chain version is `fileprivate` to its file. Tiny method, kept
    /// inline rather than exposing the helper publicly.
    private func doSubscriptInChain(receiver: Value, args: [Value]) async throws -> Value {
        guard args.count == 1 else {
            throw RuntimeError.invalid("subscript expects 1 argument, got \(args.count)")
        }
        switch (receiver, args[0]) {
        case let (.array(arr), .int(i)):
            guard i >= 0 && i < arr.count else {
                throw RuntimeError.invalid(
                    "array index \(i) out of bounds (count \(arr.count))"
                )
            }
            return arr[i]
        default:
            throw RuntimeError.invalid(
                "cannot subscript \(typeName(receiver)) with \(typeName(args[0]))"
            )
        }
    }
}
