import SwiftSyntax
import SwiftParser

extension Interpreter {
    /// Run a `{ … }` block in a fresh child scope. Returns the value of the
    /// last statement in the block (so `if`/`switch`-as-expression yield a
    /// value). Runs any `defer` blocks registered in the scope when the
    /// block exits (normally or via thrown error).
    func executeBlock(_ block: CodeBlockSyntax, in scope: Scope) async throws -> Value {
        let blockScope = Scope(parent: scope)
        var caught: Error? = nil
        var last: Value = .void
        do {
            for item in block.statements {
                last = try await execute(item: item, in: blockScope)
            }
        } catch {
            caught = error
        }
        await runDeferred(in: blockScope)
        if let caught { throw caught }
        return last
    }

    /// Execute a scope's registered `defer` bodies in reverse declaration
    /// order. Errors thrown by deferred bodies are silently dropped — Swift
    /// doesn't allow `defer` to propagate errors out of a non-throwing
    /// context, and matching that behavior is simpler than introducing a
    /// secondary error channel for the common case.
    func runDeferred(in scope: Scope) async {
        for block in scope.deferred.reversed() {
            for item in block.statements {
                _ = try? await execute(item: item, in: scope)
            }
        }
        scope.deferred.removeAll()
    }

    /// Reduce a `ConditionElementListSyntax` to a Bool. Bindings introduced by
    /// `if let` / `guard let` are inserted into `bindScope` (so the caller
    /// chooses where they live: a fresh child scope for `if`/`while`, the
    /// surrounding scope for `guard`).
    func evaluateConditions(
        _ conditions: ConditionElementListSyntax,
        bindingInto bindScope: Scope
    ) async throws -> Bool {
        for cond in conditions {
            switch cond.condition {
            case .expression(let expr):
                let v = try await evaluate(expr, in: bindScope)
                guard case .bool(let b) = v else {
                    throw RuntimeError.invalid("condition must be Bool, got \(typeName(v))")
                }
                if !b { return false }
            case .optionalBinding(let binding):
                if try await !bindOptional(binding, in: bindScope) {
                    return false
                }
            case .matchingPattern(let match):
                // `if case <pattern> = <expr>` — evaluate `<expr>`, run
                // the same pattern-matcher that switch uses, and adopt
                // the bindings on success.
                let subject = try await evaluate(match.initializer.value, in: bindScope)
                guard let matched = try await matchSwitchPattern(
                    match.pattern, against: subject, in: bindScope
                ) else { return false }
                matched.copyBindings(into: bindScope)
            default:
                throw RuntimeError.unsupported(
                    "condition kind",
                    at: cond.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            }
        }
        return true
    }

    func evaluate(ifExpr: IfExprSyntax, in scope: Scope) async throws -> Value {
        let condScope = Scope(parent: scope)
        if try await evaluateConditions(ifExpr.conditions, bindingInto: condScope) {
            return try await executeBlock(ifExpr.body, in: condScope)
        }
        guard let elseBody = ifExpr.elseBody else {
            return .void
        }
        switch elseBody {
        case .ifExpr(let elseIf):
            return try await evaluate(ifExpr: elseIf, in: scope)
        case .codeBlock(let block):
            return try await executeBlock(block, in: scope)
        }
    }

    func execute(while whileStmt: WhileStmtSyntax, label: String? = nil, in scope: Scope) async throws -> Value {
        loop: while true {
            let condScope = Scope(parent: scope)
            if try await !evaluateConditions(whileStmt.conditions, bindingInto: condScope) {
                break
            }
            do {
                _ = try await executeBlock(whileStmt.body, in: condScope)
            } catch let signal as BreakSignal {
                if signal.matches(label) { break loop } else { throw signal }
            } catch let signal as ContinueSignal {
                if signal.matches(label) { continue loop } else { throw signal }
            }
        }
        return .void
    }

    func execute(repeat repeatStmt: RepeatStmtSyntax, label: String? = nil, in scope: Scope) async throws -> Value {
        loop: while true {
            do {
                _ = try await executeBlock(repeatStmt.body, in: scope)
            } catch let signal as BreakSignal {
                if signal.matches(label) { return .void } else { throw signal }
            } catch let signal as ContinueSignal {
                if !signal.matches(label) { throw signal }
                // fall through to condition check
            }
            let v = try await evaluate(repeatStmt.condition, in: scope)
            guard case .bool(let b) = v else {
                throw RuntimeError.invalid("repeat-while condition must be Bool, got \(typeName(v))")
            }
            if !b { break loop }
        }
        return .void
    }

    func execute(forIn forStmt: ForStmtSyntax, label: String? = nil, in scope: Scope) async throws -> Value {
        let sequenceValue = try await evaluate(forStmt.sequence, in: scope)
        let elements = try await iterableElements(of: sequenceValue, at: forStmt.sequence.positionAfterSkippingLeadingTrivia.utf8Offset)
        let isCasePattern = forStmt.caseKeyword != nil

        loop: for value in elements {
            let blockScope = Scope(parent: scope)
            if isCasePattern {
                // `for case let x? in opts` / `for case .foo(let n) in arr`
                // — run the same matcher that switch uses. A failed match
                // skips this element rather than binding it.
                guard let matched = try await matchSwitchPattern(
                    forStmt.pattern, against: value, in: scope
                ) else { continue loop }
                matched.copyBindings(into: blockScope)
            } else {
                try await bindForInPattern(forStmt.pattern, value: value, in: blockScope)
            }
            if let whereClause = forStmt.whereClause {
                let cond = try await evaluate(whereClause.condition, in: blockScope)
                guard case .bool(let pass) = cond else {
                    throw RuntimeError.invalid("for-in where: condition must be Bool, got \(typeName(cond))")
                }
                if !pass { continue }
            }
            do {
                for item in forStmt.body.statements {
                    _ = try await execute(item: item, in: blockScope)
                }
            } catch let signal as BreakSignal {
                if signal.matches(label) { break loop } else { throw signal }
            } catch let signal as ContinueSignal {
                if signal.matches(label) { continue loop } else { throw signal }
            }
        }
        return .void
    }

    func execute(guard guardStmt: GuardStmtSyntax, in scope: Scope) async throws -> Value {
        // Bindings from `guard let` go into the *surrounding* scope (that's
        // the whole point of `guard`).
        if try await evaluateConditions(guardStmt.conditions, bindingInto: scope) {
            return .void
        }
        let blockScope = Scope(parent: scope)
        for item in guardStmt.body.statements {
            _ = try await execute(item: item, in: blockScope)
        }
        // The else-block must transfer control (return/break/continue/throw).
        // If we reach here, it didn't.
        throw RuntimeError.invalid("guard's else block must transfer control out")
    }

    /// Bind a `for x in …` pattern: identifier, wildcard, or tuple of
    /// identifiers/wildcards. Recurses for nested tuples.
    private func bindForInPattern(_ pattern: PatternSyntax, value: Value, in scope: Scope) async throws {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            scope.bind(ident.identifier.text, value: value, mutable: false)
            return
        }
        if pattern.is(WildcardPatternSyntax.self) { return }
        if let tup = pattern.as(TuplePatternSyntax.self) {
            guard case .tuple(let elements, _) = value else {
                throw RuntimeError.invalid(
                    "for-in tuple pattern requires a tuple value, got \(typeName(value))"
                )
            }
            let patterns = Array(tup.elements)
            guard patterns.count == elements.count else {
                throw RuntimeError.invalid(
                    "for-in tuple pattern has \(patterns.count) element(s), value has \(elements.count)"
                )
            }
            for (subPat, subVal) in zip(patterns, elements) {
                try await bindForInPattern(subPat.pattern, value: subVal, in: scope)
            }
            return
        }
        throw RuntimeError.unsupported(
            "for-in pattern \(pattern.syntaxNodeType)",
            at: pattern.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    /// Iterable adapter for `for x in y` loops. Built-in iterables go
    /// through the `ScriptSequence` adapter; script-defined sequences
    /// are duck-typed by looking for `makeIterator()` returning
    /// something with a `next() -> Optional<T>` method (the same
    /// signature `Sequence` / `IteratorProtocol` would require).
    /// We materialize all elements eagerly so the surrounding `for`
    /// loop stays a synchronous sequence walk over `[Value]`.
    private func iterableElements(of value: Value, at offset: Int) async throws -> [Value] {
        if ScriptSequence.isIterable(value) {
            return Array(ScriptSequence(value))
        }
        // Script-side `Sequence` conformance: receiver supplies a
        // `makeIterator()` zero-arg method whose result responds to
        // `next() -> Optional<T>`. We don't validate the actual
        // protocol — duck-typing matches Swift's behavior closely
        // enough for the iteration sites that care.
        if try await hasZeroArgMethod(value, named: "makeIterator") {
            let iterator = try await invokeMethod(
                "makeIterator", on: value, args: [], at: offset
            )
            return try await drainIterator(iterator, at: offset)
        }
        throw RuntimeError.invalid("not iterable: \(typeName(value))")
    }

    /// True if `value`'s type defines a no-arg `methodName`. Used as a
    /// cheap duck-type probe before we commit to invoking it.
    private func hasZeroArgMethod(_ value: Value, named methodName: String) async throws -> Bool {
        switch value {
        case .structValue(let typeName, _):
            return structDefs[typeName]?.methods[methodName] != nil
        case .classInstance(let inst):
            if let def = classDefs[inst.typeName],
               lookupClassMethod(on: def, methodName) != nil
            {
                return true
            }
            return false
        case .enumValue(let typeName, _, _):
            return enumDefs[typeName]?.methods[methodName] != nil
        default:
            return false
        }
    }

    /// Pull values out of a script-side iterator until `next()` returns
    /// `.optional(nil)`. The iterator's `next` is mutating in real
    /// Swift, but our struct-method dispatch already writes the new
    /// `self` back through the receiver chain, so a plain call works.
    private func drainIterator(_ iterator: Value, at offset: Int) async throws -> [Value] {
        var result: [Value] = []
        // Hold the iterator state in a freshly-bound mutable scope so
        // the mutating `next()` writes back through `self`. We rebuild
        // the receiver each loop with whatever `invokeMethod` produces
        // for the new `self` — for class instances it's the same ref;
        // for value types `invokeMethod` updates a temporary scope.
        var current = iterator
        // Step counter is a cheap runaway guard. ~100M is way more
        // than any reasonable script `for` loop and stops a buggy
        // iterator from spinning forever.
        for _ in 0..<100_000_000 {
            let r = try await invokeIteratorNext(&current, at: offset)
            switch r {
            case .optional(.none): return result
            case .optional(.some(let v)): result.append(v)
            default:
                throw RuntimeError.invalid(
                    "iterator's next() must return Optional, got \(typeName(r))"
                )
            }
        }
        throw RuntimeError.invalid("iterator emitted >100M elements; aborting")
    }

    /// Call `next()` on a script iterator and write the (possibly
    /// mutated) iterator state back to `current`. For value-type
    /// iterators this is essential — `mutating func next()` updates
    /// a fresh `self`, and the new state lives in the writeback.
    private func invokeIteratorNext(
        _ current: inout Value,
        at offset: Int
    ) async throws -> Value {
        // Use a local scope to host the iterator under a known name,
        // then dispatch through the same mutating-method machinery the
        // call evaluator already uses. That handles writeback for
        // structs (rebuild with new `self`) and is a no-op for
        // classes (ref cell mutates in place).
        let scope = Scope(parent: rootScope)
        scope.bind("__iter__", value: current, mutable: true)
        let parsed = SwiftParser.Parser.parse(source: "__iter__.next()")
        guard let stmt = parsed.statements.first?.item,
              case .expr(let expr) = stmt,
              let call = expr.as(FunctionCallExprSyntax.self)
        else {
            throw RuntimeError.invalid("internal: failed to build iterator call")
        }
        let r = try await evaluate(call: call, in: scope)
        if let updated = scope.lookup("__iter__") {
            current = updated.value
        }
        return r
    }

    /// Handle an `if let` / `while let` / `guard let` binding. Returns true if
    /// the value was non-nil and the binding was made; false if it was nil
    /// (i.e. the surrounding condition fails).
    private func bindOptional(
        _ binding: OptionalBindingConditionSyntax,
        in scope: Scope
    ) async throws -> Bool {
        guard let identPat = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw RuntimeError.unsupported(
                "non-identifier optional-binding pattern",
                at: binding.pattern.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        let name = identPat.identifier.text

        let raw: Value
        if let initClause = binding.initializer {
            raw = try await evaluate(initClause.value, in: scope)
        } else {
            // Shorthand: `if let x { … }` means `if let x = x { … }`.
            guard let outer = scope.lookup(name) else {
                throw RuntimeError.unknownIdentifier(
                    name,
                    at: binding.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            }
            raw = outer.value
        }

        guard case .optional(let inner) = raw else {
            throw RuntimeError.invalid(
                "if/while/guard let requires an Optional, got \(typeName(raw))"
            )
        }
        guard let unwrapped = inner else {
            return false
        }
        let mutable = binding.bindingSpecifier.tokenKind == .keyword(.var)
        scope.bind(name, value: unwrapped, mutable: mutable)
        return true
    }
}
