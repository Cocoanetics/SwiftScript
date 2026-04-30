import SwiftSyntax

extension Interpreter {
    /// Translate a `KeyPathExprSyntax` (`\.foo.bar`, `\Type.foo.bar`) into
    /// a one-argument closure that walks the property chain on its
    /// receiver. This is enough to make the common patterns work
    /// without needing a dedicated `Value.keyPath` case:
    ///
    ///     people.map(\.age)            // → people.map { $0.age }
    ///     people.sorted(by: \.age)     // closure call site
    ///     items.filter(\.isAvailable)
    ///
    /// Components beyond plain `.property` fall through to a runtime
    /// error — Swift's parser allows them but they're rare in script
    /// code; we surface them as "unsupported" rather than silently
    /// mis-translate.
    func evaluate(keyPath: KeyPathExprSyntax) throws -> Value {
        var steps: [String] = []
        for component in keyPath.components {
            switch component.component {
            case .property(let prop):
                steps.append(prop.declName.baseName.text)
            case .subscript:
                throw RuntimeError.unsupported(
                    "subscript in KeyPath",
                    at: component.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            case .optional:
                throw RuntimeError.unsupported(
                    "optional-chaining in KeyPath",
                    at: component.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            default:
                throw RuntimeError.unsupported(
                    "unsupported KeyPath component",
                    at: component.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            }
        }
        // Synthesize `{ $0.steps[0].steps[1]... }` as a builtin
        // closure. Receiver is the single positional arg; we walk the
        // path through struct fields, class fields, and tuple labels.
        let pathDesc = steps.joined(separator: ".")
        let fn = Function(
            name: "<keypath:\(pathDesc)>",
            parameters: [Function.Parameter(label: nil, name: "$0")],
            kind: .builtin({ [weak self] args in
                guard let self else { return .void }
                guard let receiver = args.first else {
                    throw RuntimeError.invalid("keypath closure: missing receiver")
                }
                return try await self.applyKeyPathSteps(steps, to: receiver)
            })
        )
        return .function(fn)
    }

    /// Walk a chain of property names through any combination of
    /// struct, class, tuple-label, and bridged opaque values. Used by
    /// the synthesized KeyPath closures and any other internal site
    /// that wants generic property access by name.
    func applyKeyPathSteps(_ steps: [String], to root: Value) async throws -> Value {
        var current = root
        for step in steps {
            current = try await readKeyPathStep(step, on: current)
        }
        return current
    }

    private func readKeyPathStep(_ name: String, on receiver: Value) async throws -> Value {
        switch receiver {
        case .structValue(let typeName, let fields):
            if let f = fields.first(where: { $0.name == name }) {
                return f.value
            }
            if let def = structDefs[typeName],
               let getter = def.computedProperties[name]
            {
                let (result, _) = try await invokeStructMethod(
                    getter, on: receiver, fields: fields, args: []
                )
                return result
            }
        case .classInstance(let inst):
            if let f = inst.fields.first(where: { $0.name == name }) {
                return f.value
            }
            if let def = classDefs[inst.typeName],
               let getter = lookupClassComputed(on: def, name)
            {
                return try await invokeClassMethod(
                    getter, on: inst, def: def, args: []
                )
            }
        case .tuple(let elements, let labels):
            if let idx = labels.firstIndex(of: name), idx < elements.count {
                return elements[idx]
            }
            if let idx = Int(name), idx >= 0, idx < elements.count {
                return elements[idx]
            }
        default:
            break
        }
        // Defer to the standard property-lookup path for anything else
        // (opaque values with bridged extension members, enum methods, …).
        return try await lookupProperty(
            name, on: receiver,
            at: 0
        )
    }
}
