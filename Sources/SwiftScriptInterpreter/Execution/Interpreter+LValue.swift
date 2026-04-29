import SwiftSyntax

extension Interpreter {
    /// A chained member-access path rooted at a stored variable, e.g.
    /// `line.start.x` → base="line", steps=["start", "x"]. Used so that
    /// assignments like `line.start.x = 5` can rebuild the path
    /// bottom-up and write the whole new value back to `line`.
    struct LValuePath {
        let base: String
        let steps: [String]
    }

    /// Parse `expr` as an l-value path. Returns nil for any expression
    /// that isn't a chain of `.member` accesses ending in a variable
    /// reference.
    func parseLValuePath(_ expr: ExprSyntax) -> LValuePath? {
        var steps: [String] = []
        var current: ExprSyntax = expr
        while let m = current.as(MemberAccessExprSyntax.self) {
            guard let base = m.base else { return nil }
            steps.insert(m.declName.baseName.text, at: 0)
            current = base
        }
        if let ref = current.as(DeclReferenceExprSyntax.self) {
            return LValuePath(base: ref.baseName.text, steps: steps)
        }
        return nil
    }

    /// Read the value at `path`. Returns nil if any step doesn't resolve.
    func readLValuePath(_ path: LValuePath, in scope: Scope) throws -> Value? {
        guard let binding = scope.lookup(path.base) else { return nil }
        var current = binding.value
        for step in path.steps {
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
        return current
    }

    /// Replace the value at `path` with `newValue`, rebuilding the chain
    /// bottom-up. Writes the result back to `path.base` via `scope.assign`.
    /// Throws on missing/let bindings or invalid steps.
    func writeLValuePath(
        _ path: LValuePath,
        value newValue: Value,
        in scope: Scope
    ) async throws {
        guard let binding = scope.lookup(path.base) else {
            throw RuntimeError.invalid("cannot find '\(path.base)' in scope")
        }
        // If the chain crosses a class instance, the *write* lands on
        // that ref cell and the rest of the chain doesn't need to be
        // rebuilt — class semantics already shares the instance across
        // every reference. We still walk up to the boundary so any
        // value-typed parents (struct holding a class) keep working.
        if let updated = try await setThroughChain(
            container: binding.value, steps: path.steps, value: newValue
        ) {
            // The chain hit no class boundary: write the rebuilt value
            // back to the root variable as before.
            guard binding.mutable else {
                throw RuntimeError.invalid(
                    "cannot assign through subscript: '\(path.base)' is a 'let' constant"
                )
            }
            _ = scope.assign(path.base, value: updated)
        }
    }

    /// Variant of setNested aware of `.classInstance`. Returns:
    /// - the new container value when the chain is purely value-typed
    ///   (caller must write that back to the variable);
    /// - `nil` when the write was performed in-place on a class instance
    ///   along the chain (no writeback needed).
    private func setThroughChain(
        container: Value, steps: [String], value: Value
    ) async throws -> Value? {
        if steps.isEmpty { return value }
        var rest = steps
        let head = rest.removeFirst()
        switch container {
        case .classInstance(let inst):
            guard let idx = inst.fields.firstIndex(where: { $0.name == head }) else {
                throw RuntimeError.invalid(
                    "value of type '\(inst.typeName)' has no settable member '\(head)'"
                )
            }
            if rest.isEmpty {
                inst.fields[idx].value = value
            } else if let updated = try await setThroughChain(
                container: inst.fields[idx].value, steps: rest, value: value
            ) {
                inst.fields[idx].value = updated
            }
            // Reference write: nothing to write back through the parent.
            return nil
        case .structValue(let typeName, var fields):
            guard let idx = fields.firstIndex(where: { $0.name == head }) else {
                throw RuntimeError.invalid(
                    "value of type '\(typeName)' has no settable member '\(head)'"
                )
            }
            if rest.isEmpty {
                fields[idx].value = value
                return .structValue(typeName: typeName, fields: fields)
            }
            if let updated = try await setThroughChain(
                container: fields[idx].value, steps: rest, value: value
            ) {
                fields[idx].value = updated
                return .structValue(typeName: typeName, fields: fields)
            }
            // The deeper write hit a class — propagate "nothing to do"
            // upward. The struct's own field still references the same
            // class instance.
            return nil
        case .opaque(let typeName, _):
            // Auto-bridged class property setter: the bridge generator
            // emits a paired `set var Type.member: ...` entry for each
            // mutable `var` property. Calling it mutates the underlying
            // Foundation reference in place; the opaque envelope
            // doesn't need rebuilding.
            if rest.isEmpty,
               let entry = propertyIndex["\(typeName).\(head)"],
               case .setter(let body)? = entry.setter
            {
                try await body(container, value)
                return nil
            }
            throw RuntimeError.invalid(
                "value of type '\(typeName)' has no settable member '\(head)'"
            )
        default:
            throw RuntimeError.invalid(
                "value of type '\(typeName(container))' has no settable member '\(head)'"
            )
        }
    }
}
