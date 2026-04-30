import SwiftSyntax

extension Interpreter {
    func evaluate(infix: InfixOperatorExprSyntax, in scope: Scope) async throws -> Value {
        if infix.operator.is(AssignmentExprSyntax.self) {
            return try await evaluateAssignment(lhs: infix.leftOperand, rhs: infix.rightOperand, in: scope)
        }
        guard let opExpr = infix.operator.as(BinaryOperatorExprSyntax.self) else {
            throw RuntimeError.unsupported(
                "operator \(infix.operator.syntaxNodeType)",
                at: infix.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        let op = opExpr.operator.text

        // Compound assignment: `x += y` desugars to `x = x + y`, but we want
        // the proper "left side of mutating operator" / "expected argument
        // type" wording rather than going through `applyBinary`.
        if isCompoundAssignment(op) {
            return try await evaluateCompoundAssignment(
                op: op,
                lhs: infix.leftOperand,
                rhs: infix.rightOperand,
                in: scope
            )
        }

        // Nil-coalescing: only evaluate the default if the LHS is nil.
        if op == "??" {
            let lhs = try await evaluate(infix.leftOperand, in: scope)
            if case .optional(let inner) = lhs {
                if let unwrapped = inner { return unwrapped }
                return try await evaluate(infix.rightOperand, in: scope)
            }
            // Non-Optional left side: the default is unreachable in Swift,
            // but for the PoC we just return the LHS unchanged.
            return lhs
        }

        // Short-circuit boolean operators evaluate the rhs lazily.
        if op == "&&" || op == "||" {
            let lhs = try await evaluate(infix.leftOperand, in: scope)
            guard case .bool(let lv) = lhs else {
                throw RuntimeError.invalid("'\(op)' requires Bool, got \(typeName(lhs))")
            }
            if op == "&&" && !lv { return .bool(false) }
            if op == "||" &&  lv { return .bool(true) }
            let rhs = try await evaluate(infix.rightOperand, in: scope)
            guard case .bool(let rv) = rhs else {
                throw RuntimeError.invalid("'\(op)' requires Bool, got \(typeName(rhs))")
            }
            return .bool(rv)
        }

        let lhs = try await evaluate(infix.leftOperand, in: scope)
        let rhs = try await evaluate(infix.rightOperand, in: scope)
        return try await applyBinary(
            op: op,
            lhs: lhs, lhsExpr: infix.leftOperand,
            rhs: rhs, rhsExpr: infix.rightOperand
        )
    }

    func applyBinary(
        op: String,
        lhs: Value, lhsExpr: ExprSyntax,
        rhs: Value, rhsExpr: ExprSyntax
    ) async throws -> Value {
        // User-defined infix operator (`func **(_ a: Int, _ b: Int) -> Int`).
        // Built-ins win for the standard operator set; anything outside it
        // dispatches to a free-function binding with the same name.
        if !Self.builtinBinaryOperators.contains(op),
           let binding = rootScope.lookup(op),
           case .function(let fn) = binding.value
        {
            return try await invoke(fn, args: [lhs, rhs])
        }
        switch (lhs, rhs) {
        case let (.int(a), .int(b)):
            switch op {
            case "+":   return .int(a + b)
            case "-":   return .int(a - b)
            case "*":   return .int(a * b)
            case "/":   guard b != 0 else { throw RuntimeError.divisionByZero }; return .int(a / b)
            case "%":   guard b != 0 else { throw RuntimeError.divisionByZero }; return .int(a % b)
            case "==":  return .bool(a == b)
            case "!=":  return .bool(a != b)
            case "<":   return .bool(a < b)
            case ">":   return .bool(a > b)
            case "<=":  return .bool(a <= b)
            case ">=":  return .bool(a >= b)
            case "..<": return .range(lower: a, upper: b, closed: false)
            case "...": return .range(lower: a, upper: b, closed: true)
            case "<<": return .int(a << b)
            case ">>": return .int(a >> b)
            case "&":  return .int(a & b)
            case "|":  return .int(a | b)
            case "^":  return .int(a ^ b)
            default:    throw RuntimeError.invalid("binary operator '\(op)' cannot be applied to two 'Int' operands")
            }
        case let (.double(a), .double(b)):
            return try await applyDouble(op: op, a: a, b: b)
        case let (.int(a), .double(b)):
            // Mixed Int/Double: promote the Int side. Swift's compile-time
            // rule is "literals adapt, variables don't", but at runtime
            // we can't recover whether an Int flowed in from a literal
            // (e.g. `reduce(0, +)` — the `0` is already an `.int` by the
            // time the closure runs). Promoting unconditionally lets
            // valid Swift programs run with the same numeric results.
            return try await applyDouble(op: op, a: Double(a), b: b)
        case let (.double(a), .int(b)):
            return try await applyDouble(op: op, a: a, b: Double(b))
        case let (.string(a), .string(b)):
            switch op {
            case "+":  return .string(a + b)
            case "==": return .bool(a == b)
            case "!=": return .bool(a != b)
            case "<":  return .bool(a < b)
            case ">":  return .bool(a > b)
            case "<=": return .bool(a <= b)
            case ">=": return .bool(a >= b)
            default:   throw RuntimeError.invalid("binary operator '\(op)' cannot be applied to two 'String' operands")
            }
        case let (.bool(a), .bool(b)):
            switch op {
            case "==": return .bool(a == b)
            case "!=": return .bool(a != b)
            default:   throw RuntimeError.invalid("binary operator '\(op)' cannot be applied to two 'Bool' operands")
            }
        case let (.array(a), .array(b)):
            switch op {
            case "+":  return .array(a + b)
            case "==": return .bool(a == b)
            case "!=": return .bool(a != b)
            default:
                throw RuntimeError.invalid(
                    "binary operator '\(op)' cannot be applied to two '\(typeName(lhs))' operands"
                )
            }
        case let (.enumValue(an, _, _), .enumValue(bn, _, _)) where an == bn:
            // Enum-defined `static func <op>` overloads take precedence;
            // otherwise the default `==`/`!=` comes from Value's Equatable.
            if let opFn = enumDefs[an]?.staticMembers[op],
               case .function(let fn) = opFn
            {
                return try await invoke(fn, args: [lhs, rhs])
            }
            switch op {
            case "==": return .bool(lhs == rhs)
            case "!=": return .bool(lhs != rhs)
            default:
                throw RuntimeError.invalid(
                    "binary operator '\(op)' cannot be applied to operands of type '\(typeName(lhs))' and '\(typeName(rhs))'"
                )
            }
        case let (.structValue(an, _), .structValue(bn, _)) where an == bn:
            // User-declared `static func <op>(a: T, b: T) -> …` takes
            // precedence; otherwise default to memberwise equality.
            if let opFn = structDefs[an]?.staticMembers[op],
               case .function(let fn) = opFn
            {
                return try await invoke(fn, args: [lhs, rhs])
            }
            switch op {
            case "==": return .bool(lhs == rhs)
            case "!=": return .bool(lhs != rhs)
            default:
                throw RuntimeError.invalid(
                    "binary operator '\(op)' cannot be applied to operands of type '\(typeName(lhs))' and '\(typeName(rhs))'"
                )
            }
        case let (.opaque(an, _), .opaque(bn, _)) where an == bn:
            // Opaque values whose carrying type registered a comparator
            // (Date, Decimal, …). `<`/`<=`/`>`/`>=`/`==`/`!=` all route
            // through the same compare-by-int closure.
            if let compare = opaqueComparators[an] {
                let r = try compare(lhs, rhs)
                switch op {
                case "==": return .bool(r == 0)
                case "!=": return .bool(r != 0)
                case "<":  return .bool(r < 0)
                case ">":  return .bool(r > 0)
                case "<=": return .bool(r <= 0)
                case ">=": return .bool(r >= 0)
                default:
                    throw RuntimeError.invalid("binary operator '\(op)' cannot be applied to two '\(an)' operands")
                }
            }
            throw RuntimeError.invalid(
                "binary operator '\(op)' cannot be applied to two '\(an)' operands"
            )

        case let (.tuple(a, _), .tuple(b, _)):
            // Swift supports `==`/`!=` on same-arity tuples whose
            // elements are themselves Equatable. We compare structurally.
            switch op {
            case "==": return .bool(a.count == b.count && zip(a, b).allSatisfy { $0 == $1 })
            case "!=": return .bool(!(a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }))
            default:
                throw RuntimeError.invalid(
                    "binary operator '\(op)' cannot be applied to two '\(typeName(lhs))' operands"
                )
            }

        case (.optional, _), (_, .optional):
            // `==` / `!=`. Swift lifts a non-optional operand to the
            // matching `Optional<T>` so `let a: Int? = 5; a == 5` is
            // `Optional(5) == Optional(5)` → true. Mirror that lift.
            let liftedL: Value = { if case .optional = lhs { return lhs } else { return .optional(lhs) } }()
            let liftedR: Value = { if case .optional = rhs { return rhs } else { return .optional(rhs) } }()
            switch op {
            case "==": return .bool(liftedL == liftedR)
            case "!=": return .bool(liftedL != liftedR)
            default:
                throw RuntimeError.invalid(
                    "binary operator '\(op)' cannot be applied to operands of type '\(typeName(lhs))' and '\(typeName(rhs))'"
                )
            }
        default:
            throw RuntimeError.invalid(
                "binary operator '\(op)' cannot be applied to operands of type '\(typeName(lhs))' and '\(typeName(rhs))'"
            )
        }
    }

    private func applyDouble(op: String, a: Double, b: Double) async throws -> Value {
        switch op {
        case "+":  return .double(a + b)
        case "-":  return .double(a - b)
        case "*":  return .double(a * b)
        case "/":  return .double(a / b)
        case "==": return .bool(a == b)
        case "!=": return .bool(a != b)
        case "<":  return .bool(a < b)
        case ">":  return .bool(a > b)
        case "<=": return .bool(a <= b)
        case ">=": return .bool(a >= b)
        default:   throw RuntimeError.invalid("operator '\(op)' not defined for Double")
        }
    }

    func applyPrefix(op: String, value: Value) async throws -> Value {
        switch (op, value) {
        case ("-", .int(let i)):    return .int(-i)
        case ("-", .double(let d)): return .double(-d)
        case ("+", .int(let i)):    return .int(i)
        case ("+", .double(let d)): return .double(d)
        case ("!", .bool(let b)):   return .bool(!b)
        case ("~", .int(let i)):    return .int(~i)
        default:
            throw RuntimeError.invalid(
                "unary operator '\(op)' cannot be applied to an operand of type '\(typeName(value))'"
            )
        }
    }

    private func isCompoundAssignment(_ op: String) -> Bool {
        // Operator must end in `=` but not be a comparison.
        guard op.hasSuffix("=") else { return false }
        return !["==", "!=", "<=", ">="].contains(op)
    }

    /// Operators applyBinary handles natively. Everything else routes to
    /// a user-declared free function with that name.
    static let builtinBinaryOperators: Set<String> = [
        "+", "-", "*", "/", "%",
        "==", "!=", "<", ">", "<=", ">=",
        "&&", "||", "??",
        "..<", "...",
        "<<", ">>", "&", "|", "^",
        "&+", "&-", "&*",
    ]

    private func evaluateCompoundAssignment(
        op: String,
        lhs: ExprSyntax,
        rhs: ExprSyntax,
        in scope: Scope
    ) async throws -> Value {
        let baseOp = String(op.dropLast()) // "+=" → "+"

        // `x += rhs` — bare identifier LHS.
        if let ref = lhs.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            // Apply the same precedence rule as plain assignment: a
            // binding inside the method body (param/local) wins; outer
            // captured vars lose to implicit-self.
            let nameOwner = scope.lookupWithOwner(name)
            let selfOwner = scope.lookupWithOwner("self")
            let preferSelf: Bool = {
                guard let (_, selfScope) = selfOwner else { return false }
                if let (_, owner) = nameOwner {
                    return !selfScope.isAncestor(of: owner)
                }
                return true
            }()
            if !preferSelf, let binding = nameOwner?.0 {
                guard binding.mutable else {
                    throw RuntimeError.invalid(
                        "left side of mutating operator isn't mutable: '\(name)' is a 'let' constant"
                    )
                }
                let lhsValue = binding.value
                var rhsValue = try await evaluate(rhs, in: scope)
                rhsValue = try await coerceCompoundRHS(lhs: lhsValue, rhs: rhsValue, rhsExpr: rhs)
                let newValue = try await applyBinary(
                    op: baseOp,
                    lhs: lhsValue, lhsExpr: lhs,
                    rhs: rhsValue, rhsExpr: rhs
                )
                _ = scope.assign(name, value: newValue)
                return .void
            }
            // Implicit-self property: `n += …` inside a struct method.
            if let selfBinding = scope.lookup("self"),
               case .structValue(let structName, var fields) = selfBinding.value,
               let idx = fields.firstIndex(where: { $0.name == name })
            {
                guard selfBinding.mutable else {
                    throw RuntimeError.invalid(
                        "left side of mutating operator isn't mutable: 'self' is immutable"
                    )
                }
                let lhsValue = fields[idx].value
                var rhsValue = try await evaluate(rhs, in: scope)
                rhsValue = try await coerceCompoundRHS(lhs: lhsValue, rhs: rhsValue, rhsExpr: rhs)
                let newValue = try await applyBinary(
                    op: baseOp,
                    lhs: lhsValue, lhsExpr: lhs,
                    rhs: rhsValue, rhsExpr: rhs
                )
                fields[idx].value = newValue
                _ = scope.assign("self", value: .structValue(typeName: structName, fields: fields))
                return .void
            }
            // Compound assign on a class field: read the current value,
            // apply, write back through the reference cell.
            if let selfBinding = scope.lookup("self"),
               case .classInstance(let inst) = selfBinding.value,
               let idx = inst.fields.firstIndex(where: { $0.name == name })
            {
                let lhsValue = inst.fields[idx].value
                var rhsValue = try await evaluate(rhs, in: scope)
                rhsValue = try await coerceCompoundRHS(lhs: lhsValue, rhs: rhsValue, rhsExpr: rhs)
                let newValue = try await applyBinary(
                    op: baseOp,
                    lhs: lhsValue, lhsExpr: lhs,
                    rhs: rhsValue, rhsExpr: rhs
                )
                inst.fields[idx].value = newValue
                return .void
            }
            // Implicit-Self static-member compound assign: `total += 1`
            // inside a `static func` body writes back to `staticMembers`.
            // Works for structs and (with chain walk) classes.
            if let staticOwner = staticContextStack.last,
               let info = readStaticMember(owner: staticOwner, name: name)
            {
                var rhsValue = try await evaluate(rhs, in: scope)
                rhsValue = try await coerceCompoundRHS(lhs: info.value, rhs: rhsValue, rhsExpr: rhs)
                let newValue = try await applyBinary(
                    op: baseOp,
                    lhs: info.value, lhsExpr: lhs,
                    rhs: rhsValue, rhsExpr: rhs
                )
                writeStaticMember(owner: info.owningType, kind: info.kind, name: name, value: newValue)
                return .void
            }
            throw RuntimeError.invalid("cannot find '\(name)' in scope")
        }

        // `obj.prop += rhs` and chained forms `b.p.x += rhs`.
        if let path = parseLValuePath(lhs), !path.steps.isEmpty {
            guard let binding = scope.lookup(path.base) else {
                throw RuntimeError.invalid("cannot find '\(path.base)' in scope")
            }
            guard binding.mutable else {
                let label = (path.base == "self") ? "'self' is immutable"
                                                  : "'\(path.base)' is a 'let' constant"
                throw RuntimeError.invalid(
                    "left side of mutating operator isn't mutable: \(label)"
                )
            }
            guard let lhsValue = try readLValuePath(path, in: scope) else {
                throw RuntimeError.invalid("cannot resolve '\(path.steps.joined(separator: "."))'")
            }
            var rhsValue = try await evaluate(rhs, in: scope)
            rhsValue = try await coerceCompoundRHS(lhs: lhsValue, rhs: rhsValue, rhsExpr: rhs)
            let newValue = try await applyBinary(
                op: baseOp,
                lhs: lhsValue, lhsExpr: lhs,
                rhs: rhsValue, rhsExpr: rhs
            )
            try await writeLValuePath(path, value: newValue, in: scope)
            return .void
        }

        throw RuntimeError.invalid(
            "left side of mutating operator must be an identifier or property reference"
        )
    }

    /// Coerce the RHS of a compound-assignment against the LHS's runtime
    /// type. Rules mirror Swift: same-type passes; integer literals adapt to
    /// Double; otherwise it's "cannot convert value of type 'X' to expected
    /// argument type 'Y'".
    private func coerceCompoundRHS(
        lhs: Value,
        rhs: Value,
        rhsExpr: ExprSyntax
    ) async throws -> Value {
        switch (lhs, rhs) {
        case (.int, .int), (.double, .double), (.string, .string), (.array, .array):
            return rhs
        case (.double, .int(let i)):
            if literalKind(rhsExpr) == .integerLiteral {
                return .double(Double(i))
            }
            throw RuntimeError.invalid(
                "cannot convert value of type 'Int' to expected argument type 'Double'"
            )
        case (.int, .double):
            throw RuntimeError.invalid(
                "cannot convert value of type 'Double' to expected argument type 'Int'"
            )
        default:
            throw RuntimeError.invalid(
                "cannot convert value of type '\(typeName(rhs))' to expected argument type '\(typeName(lhs))'"
            )
        }
    }

    private func evaluateAssignment(lhs: ExprSyntax, rhs: ExprSyntax, in scope: Scope) async throws -> Value {
        // Discard assignment: `_ = expr`. Evaluates the RHS for its side
        // effects (and `try` propagation) and discards the value. Common
        // when the RHS is a `try`-wrapped throwing call whose result the
        // caller doesn't care about.
        if lhs.is(DiscardAssignmentExprSyntax.self) {
            _ = try await evaluate(rhs, in: scope)
            return .void
        }
        // Plain identifier LHS: `x = …`.
        if let ref = lhs.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            // Use the binding's declared type so `possibleInteger = .some(100)`
            // can resolve the implicit-member access against the enum type.
            let lhsType = scope.lookup(name)?.declaredType
            let value = try await evaluate(rhs, expecting: lhsType, in: scope)
            // Same precedence rule as the read path: a binding inside the
            // current method body (parameters/locals) wins; an implicit-
            // self field wins over a captured outer var of the same
            // name. Lets `triangle = …` inside a class init mean
            // `self.triangle = …` even when an outer `var triangle`
            // exists at top level.
            let nameOwner = scope.lookupWithOwner(name)
            let selfOwner = scope.lookupWithOwner("self")
            if let (selfBinding, selfScope) = selfOwner {
                let nameInsideMethod = nameOwner.map { selfScope.isAncestor(of: $0.1) } ?? false
                if !nameInsideMethod {
                    if case .structValue(let structName, var fields) = selfBinding.value,
                       let idx = fields.firstIndex(where: { $0.name == name })
                    {
                        guard selfBinding.mutable else {
                            throw RuntimeError.invalid(
                                "left side of mutating operator isn't mutable: 'self' is immutable"
                            )
                        }
                        fields[idx].value = value
                        _ = scope.assign("self", value: .structValue(typeName: structName, fields: fields))
                        return .void
                    }
                    if case .classInstance(let inst) = selfBinding.value {
                        if let idx = inst.fields.firstIndex(where: { $0.name == name }) {
                            // Outside init, observers fire around this write.
                            // Inside init they're suppressed (Swift rule).
                            if let def = classDefs[inst.typeName],
                               !instancesInInit.contains(ObjectIdentifier(inst)),
                               (lookupClassWillSet(on: def, name) != nil
                                || lookupClassDidSet(on: def, name) != nil)
                            {
                                let oldValue = inst.fields[idx].value
                                if let willSet = lookupClassWillSet(on: def, name) {
                                    _ = try await invokeClassMethod(willSet, on: inst, def: def, args: [value])
                                }
                                inst.fields[idx].value = value
                                if let didSet = lookupClassDidSet(on: def, name) {
                                    _ = try await invokeClassMethod(didSet, on: inst, def: def, args: [oldValue])
                                }
                                return .void
                            }
                            inst.fields[idx].value = value
                            return .void
                        }
                        if let def = classDefs[inst.typeName],
                           let setter = findClassSetter(on: def, name)
                        {
                            _ = try await invokeClassMethod(setter, on: inst, def: def, args: [value])
                            return .void
                        }
                    }
                }
            }
            if scope.assign(name, value: value) {
                return .void
            }
            // Implicit-Self static-member assign: `total = 0` inside a
            // `static func` body writes back to `staticMembers`. Walks
            // struct + class-inheritance chains.
            if let staticOwner = staticContextStack.last,
               let info = readStaticMember(owner: staticOwner, name: name)
            {
                writeStaticMember(owner: info.owningType, kind: info.kind, name: name, value: value)
                return .void
            }
            if scope.lookup(name) == nil {
                throw RuntimeError.unknownIdentifier(name, at: lhs.positionAfterSkippingLeadingTrivia.utf8Offset)
            }
            throw RuntimeError.invalid("cannot assign to value: '\(name)' is a 'let' constant")
        }
        // Subscript assignment: `d[k] = v`, `arr[i] = v`. The base must be
        // a mutable variable so we can write the modified container back.
        if let subscriptCall = lhs.as(SubscriptCallExprSyntax.self),
           let baseRef = subscriptCall.calledExpression.as(DeclReferenceExprSyntax.self)
        {
            let varName = baseRef.baseName.text
            guard let binding = scope.lookup(varName) else {
                throw RuntimeError.invalid("cannot find '\(varName)' in scope")
            }
            guard binding.mutable else {
                throw RuntimeError.invalid(
                    "cannot assign through subscript: '\(varName)' is a 'let' constant"
                )
            }
            let args = try await subscriptCall.arguments.asyncMap { try await evaluate($0.expression, in: scope) }
            let value = try await evaluate(rhs, in: scope)
            switch binding.value {
            case .dict(var entries):
                guard args.count == 1 else {
                    throw RuntimeError.invalid("dictionary subscript expects 1 key")
                }
                let key = args[0]
                if case .optional(.none) = value {
                    entries.removeAll { $0.key == key }
                } else if let i = entries.firstIndex(where: { $0.key == key }) {
                    entries[i].value = value
                } else {
                    entries.append(DictEntry(key: key, value: value))
                }
                _ = scope.assign(varName, value: .dict(entries))
                return .void
            case .array(var arr):
                guard args.count == 1, case .int(let i) = args[0] else {
                    throw RuntimeError.invalid("array subscript expects 1 Int index")
                }
                guard i >= 0 && i < arr.count else {
                    throw RuntimeError.invalid(
                        "array index \(i) out of bounds (count \(arr.count))"
                    )
                }
                // Strict element-type: `arr: [Int]` rejects assignment of
                // a non-Int value through the subscript.
                if let elementType = binding.declaredType
                    .flatMap({ $0.as(ArrayTypeSyntax.self)?.element }),
                   !valueMatchesType(value, elementType),
                   !isGenericPlaceholder(elementType.description.trimmingCharacters(in: .whitespaces))
                {
                    throw RuntimeError.invalid(
                        "cannot assign value of type '\(typeName(value))' to subscript of type '\(elementType.description.trimmingCharacters(in: .whitespaces))'"
                    )
                }
                arr[i] = value
                _ = scope.assign(varName, value: .array(arr))
                return .void
            default:
                throw RuntimeError.invalid(
                    "value of type '\(typeName(binding.value))' is not subscriptable for assignment"
                )
            }
        }

        // Property assignment chain: `p.x = …`, `line.start.x = …`, etc.
        // Walk the LHS as an l-value path and write back through the chain.
        if let path = parseLValuePath(lhs), !path.steps.isEmpty {
            // Implicit-self precedence: if the path's base names a stored
            // property of the current `self` *and* any outer-captured var
            // also has that name, prefer the property. Mirrors the
            // identifier-read precedence rule.
            let baseOwner = scope.lookupWithOwner(path.base)
            let selfOwner = scope.lookupWithOwner("self")
            if let (selfBinding, selfScope) = selfOwner {
                let baseInsideMethod = baseOwner.map { selfScope.isAncestor(of: $0.1) } ?? false
                if !baseInsideMethod {
                    if case .structValue(_, let fields) = selfBinding.value,
                       fields.contains(where: { $0.name == path.base })
                    {
                        let rewritten = LValuePath(
                            base: "self", steps: [path.base] + path.steps
                        )
                        var newValue = try await evaluate(rhs, in: scope)
                        if let leafType = leafPropertyType(selfBinding.value, steps: rewritten.steps) {
                            newValue = try await coerce(value: newValue, expr: rhs, toType: leafType, in: .argument)
                        }
                        try await writeLValuePath(rewritten, value: newValue, in: scope)
                        return .void
                    }
                    if case .classInstance(let inst) = selfBinding.value,
                       inst.fields.contains(where: { $0.name == path.base })
                    {
                        let rewritten = LValuePath(
                            base: "self", steps: [path.base] + path.steps
                        )
                        var newValue = try await evaluate(rhs, in: scope)
                        if let leafType = leafPropertyType(selfBinding.value, steps: rewritten.steps) {
                            newValue = try await coerce(value: newValue, expr: rhs, toType: leafType, in: .argument)
                        }
                        try await writeLValuePath(rewritten, value: newValue, in: scope)
                        return .void
                    }
                }
            }
            guard let binding = scope.lookup(path.base) else {
                throw RuntimeError.invalid("cannot find '\(path.base)' in scope")
            }
            // Class roots: a `let alias = shape` still allows
            // `alias.numberOfSides = …` because the let only freezes the
            // reference, not the pointee. Skip the mutability check when
            // the very first hop crosses a class instance — including
            // an `.opaque` whose underlying payload is a Foundation
            // reference type (auto-bridged classes like JSONEncoder).
            let rootIsClass = (path.steps.count > 0)
                && {
                    if case .classInstance = binding.value { return true }
                    if case .opaque(let typeName, _) = binding.value,
                       isAutoBridgedClass(typeName)
                    {
                        return true
                    }
                    return false
                }()
            if !rootIsClass {
                guard binding.mutable else {
                    let label = (path.base == "self") ? "'self' is immutable"
                                                      : "'\(path.base)' is a 'let' constant"
                    throw RuntimeError.invalid(
                        "cannot assign to property: \(label)"
                    )
                }
            }
            // Coerce against the leaf property's declared type if we know it.
            // Two paths:
            //   - Value-typed leaf: `leafPropertyType` returns a TypeSyntax
            //     and we coerce against it.
            //   - Opaque-bridged leaf (auto-bridged class property):
            //     consult `propertyIndex` for the declared type spelling
            //     and use it as the implicit-member context so
            //     `.prettyPrinted` / `[.a, .b]` against an OptionSet
            //     property type resolves correctly.
            var newValue: Value
            let bridgedPropType: String?
            if path.steps.count == 1,
               case .opaque(let typeName, _) = binding.value,
               let entry = propertyIndex["\(typeName).\(path.steps[0])"]
            {
                bridgedPropType = entry.typeSpelling.isEmpty ? nil : entry.typeSpelling
            } else {
                bridgedPropType = nil
            }
            if let bridgedPropType {
                newValue = try await evaluate(rhs, expectingTypeName: bridgedPropType, in: scope)
            } else {
                newValue = try await evaluate(rhs, in: scope)
                if let leafType = leafPropertyType(binding.value, steps: path.steps) {
                    newValue = try await coerce(value: newValue, expr: rhs, toType: leafType, in: .argument)
                }
            }
            // Setter dispatch: walk the chain to the leaf, and if it's a
            // class computed property (with a setter), call the setter
            // instead of writing a stored field.
            if path.steps.count == 1,
               case .classInstance(let inst) = binding.value,
               let def = classDefs[inst.typeName],
               inst.fields.first(where: { $0.name == path.steps[0] }) == nil,
               let setter = findClassSetter(on: def, path.steps[0])
            {
                _ = try await invokeClassMethod(setter, on: inst, def: def, args: [newValue])
                return .void
            }
            // Property observers (willSet/didSet) on a class field: fire
            // around the write. Suppressed while the instance is being
            // initialized — matches Swift's rule that observers don't
            // fire inside the owning class's `init`.
            if path.steps.count == 1,
               case .classInstance(let inst) = binding.value,
               let def = classDefs[inst.typeName],
               let leafField = inst.fields.first(where: { $0.name == path.steps[0] }),
               !instancesInInit.contains(ObjectIdentifier(inst)),
               (lookupClassWillSet(on: def, path.steps[0]) != nil ||
                lookupClassDidSet(on: def, path.steps[0]) != nil)
            {
                let oldValue = leafField.value
                if let willSet = lookupClassWillSet(on: def, path.steps[0]) {
                    _ = try await invokeClassMethod(willSet, on: inst, def: def, args: [newValue])
                }
                try await writeLValuePath(path, value: newValue, in: scope)
                if let didSet = lookupClassDidSet(on: def, path.steps[0]) {
                    _ = try await invokeClassMethod(didSet, on: inst, def: def, args: [oldValue])
                }
                return .void
            }
            try await writeLValuePath(path, value: newValue, in: scope)
            return .void
        }
        throw RuntimeError.invalid(
            "left-hand side of '=' must be an identifier or a property reference (got \(lhs.syntaxNodeType))"
        )
    }

    /// Walk `value`'s struct fields along `steps` (all but the leaf) and
    /// return the *leaf step's* declared property type, if known. Used to
    /// coerce RHS during chained assignment.
    private func leafPropertyType(_ value: Value, steps: [String]) -> TypeSyntax? {
        guard let last = steps.last else { return nil }
        var current = value
        for step in steps.dropLast() {
            switch current {
            case .structValue(_, let fields):
                guard let f = fields.first(where: { $0.name == step }) else { return nil }
                current = f.value
            case .classInstance(let inst):
                guard let f = inst.fields.first(where: { $0.name == step }) else { return nil }
                current = f.value
            default:
                return nil
            }
        }
        if case .structValue(let typeName, _) = current,
           let prop = structDefs[typeName]?.properties.first(where: { $0.name == last })
        {
            return prop.type
        }
        if case .classInstance(let inst) = current {
            // Walk the inheritance chain for the leaf property's type.
            for def in classDefChain(inst.typeName) {
                if let prop = def.properties.first(where: { $0.name == last }) {
                    return prop.type
                }
            }
        }
        return nil
    }
}
