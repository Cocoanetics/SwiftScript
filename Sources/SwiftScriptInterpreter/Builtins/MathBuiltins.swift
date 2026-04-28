import Foundation

/// Stdlib-level math builtins that are available without `import Foundation`.
/// Foundation-only globals (sqrt, sin, cos, …) and `pi`/`e` constants now
/// live in `Modules/FoundationModule.swift`, registered on import.
extension Interpreter {
    func registerMathBuiltins() {
        registerBuiltin(name: "abs") { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("abs: expected 1 argument, got \(args.count)")
            }
            switch args[0] {
            case .int(let i):    return .int(Swift.abs(i))
            case .double(let d): return .double(Swift.abs(d))
            default:
                throw RuntimeError.invalid("abs: expected numeric value, got \(typeName(args[0]))")
            }
        }
        registerBuiltin(name: "min") { args in
            try numericReduce(name: "min", args: args, pickInt: Swift.min, pickDouble: Swift.min)
        }
        registerBuiltin(name: "max") { args in
            try numericReduce(name: "max", args: args, pickInt: Swift.max, pickDouble: Swift.max)
        }
    }
}

private func numericReduce(
    name: String,
    args: [Value],
    pickInt: (Int, Int) -> Int,
    pickDouble: (Double, Double) -> Double
) throws -> Value {
    guard !args.isEmpty else {
        throw RuntimeError.invalid("\(name): expected at least 1 argument")
    }
    let allInt = args.allSatisfy { if case .int = $0 { return true }; return false }
    if allInt {
        var acc = Int.min
        var first = true
        for case .int(let i) in args {
            acc = first ? i : pickInt(acc, i)
            first = false
        }
        return .int(acc)
    }
    var acc = Double.nan
    var first = true
    for v in args {
        let d = try toDouble(v)
        acc = first ? d : pickDouble(acc, d)
        first = false
    }
    return .double(acc)
}
