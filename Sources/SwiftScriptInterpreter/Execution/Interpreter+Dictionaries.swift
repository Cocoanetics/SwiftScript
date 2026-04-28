import SwiftSyntax

extension Interpreter {
    /// `[k: v, k: v]` and `[:]` literals.
    func evaluate(dictExpr: DictionaryExprSyntax, in scope: Scope) async throws -> Value {
        switch dictExpr.content {
        case .colon:
            return .dict([])
        case .elements(let elements):
            var entries: [DictEntry] = []
            for element in elements {
                let k = try await evaluate(element.key, in: scope)
                let v = try await evaluate(element.value, in: scope)
                entries.append(DictEntry(key: k, value: v))
            }
            return .dict(entries)
        }
    }

    /// True if a function call is `[K: V](…)` syntax — calledExpression is
    /// a one-pair dictionary literal whose key and value are both type
    /// names. Used to detect typed-dictionary initializers like
    /// `var d = [String: Int]()`.
    func isTypedDictInitializer(_ call: FunctionCallExprSyntax) -> Bool {
        guard let dictExpr = call.calledExpression.as(DictionaryExprSyntax.self) else {
            return false
        }
        guard case .elements(let elements) = dictExpr.content,
              let first = elements.first, elements.count == 1 else {
            return false
        }
        return first.key.as(DeclReferenceExprSyntax.self) != nil &&
               first.value.as(DeclReferenceExprSyntax.self) != nil
    }
}
