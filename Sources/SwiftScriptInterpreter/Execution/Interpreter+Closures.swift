import SwiftSyntax

extension Interpreter {
    /// Build a closure value from a `ClosureExprSyntax`, capturing the
    /// surrounding lexical scope by reference.
    ///
    /// Three forms are recognised:
    /// - `{ x, y in … }`        — shorthand parameters (no types)
    /// - `{ (x: Int) -> Int in … }` — full signature
    /// - `{ $0 + $1 }`          — anonymous; `$N` references resolved at
    ///   call time (the caller binds `$0..$(n-1)` to the passed args).
    func evaluate(closure: ClosureExprSyntax, in scope: Scope) async throws -> Value {
        var parameters: [Function.Parameter] = []
        var returnType: TypeSyntax? = nil
        var captureScope: Scope? = nil

        if let signature = closure.signature {
            // Capture list `[x, y = expr]` — snapshot each named expression
            // *now* and bind into a child scope that becomes the closure's
            // captured environment. `[x]` is shorthand for `[x = x]`.
            if let captureClause = signature.capture {
                let snapshot = Scope(parent: scope)
                for item in captureClause.items {
                    // `[x]`            → name=x, initializer=nil
                    // `[y = expr]`     → name=y, initializer=expr
                    // `[weak self]`    → specifier=weak; we don't honor weak/
                    //                     unowned semantics, but the binding
                    //                     name is still derived as below.
                    let bindingName = item.name.text
                    let expression = item.initializer?.value
                        ?? ExprSyntax(DeclReferenceExprSyntax(baseName: item.name))
                    let value = try await evaluate(expression, in: scope)
                    snapshot.bind(bindingName, value: value, mutable: false)
                }
                captureScope = snapshot
            }
            if let paramClause = signature.parameterClause {
                switch paramClause {
                case .simpleInput(let names):
                    for paramSyntax in names {
                        parameters.append(Function.Parameter(
                            label: nil,
                            name: paramSyntax.name.text,
                            type: nil
                        ))
                    }
                case .parameterClause(let typed):
                    for paramSyntax in typed.parameters {
                        let firstName = paramSyntax.firstName.text
                        let internalName = paramSyntax.secondName?.text ?? firstName
                        parameters.append(Function.Parameter(
                            label: firstName == "_" ? nil : firstName,
                            name: internalName,
                            type: paramSyntax.type
                        ))
                    }
                }
            }
            returnType = signature.returnClause?.type
        }

        let function = Function(
            name: "<closure>",
            parameters: parameters,
            returnType: returnType,
            kind: .user(body: closure.statements, capturedScope: captureScope ?? scope)
        )
        return .function(function)
    }
}
