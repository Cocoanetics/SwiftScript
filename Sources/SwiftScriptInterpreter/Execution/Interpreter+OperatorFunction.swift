import SwiftSyntax

extension Interpreter {
    /// If `name` is a binary operator we support, return a `Function` value
    /// that applies it to two arguments. Used when an operator token shows
    /// up in expression position (`reduce(0, +)`, `arr.sorted(by: >)`, …).
    func operatorFunction(_ name: String) -> Value? {
        let supported: Set<String> = [
            "+", "-", "*", "/", "%",
            "<", ">", "<=", ">=", "==", "!=",
            "&&", "||",
            "..<", "...",
            // Bitwise — Int-only at the call site; matches swiftc which
            // also exposes these as overloaded `static func` on Int*.
            "&", "|", "^", "<<", ">>",
        ]
        guard supported.contains(name) else { return nil }
        let op = name
        // Build a synthetic *integer-literal* placeholder so the polymorphic
        // promotion path in `applyBinary` activates: when `reduce(0, +)` runs
        // over `[Double]`, the first call is `+(.int(0), .double(x))` and we
        // want the Int to widen. Real Swift handles this by overload
        // resolution at the call site; we don't have that, so we treat the
        // operator-as-function as if its operands came from polymorphic
        // literal expressions.
        let placeholder = ExprSyntax(
            IntegerLiteralExprSyntax(literal: .integerLiteral("0"))
        )
        let fn = Function(name: op, parameters: [], kind: .builtin({ [weak self] args in
            guard let self else { return .void }
            guard args.count == 2 else {
                throw RuntimeError.invalid("'\(op)' expects 2 arguments, got \(args.count)")
            }
            return try await self.applyBinary(
                op: op,
                lhs: args[0], lhsExpr: placeholder,
                rhs: args[1], rhsExpr: placeholder
            )
        }))
        return .function(fn)
    }
}
