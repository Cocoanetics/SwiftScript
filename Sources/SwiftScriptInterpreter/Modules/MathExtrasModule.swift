import Foundation

/// Math helpers commonly written by hand in LLM-generated math scripts:
/// extra Foundation math, number-theory utilities, signum/clamped, and
/// Array reductions.
public struct MathExtrasModule: BuiltinModule {
    public let name = "MathExtras"
    public init() {}

    public func register(into i: Interpreter) {
        registerGlobalFunctions(i)
        registerIntMethods(i)
        registerDoubleMethods(i)
        registerArrayReductions(i)
    }

    // MARK: - Global functions

    private func registerGlobalFunctions(_ i: Interpreter) {
        // Note: hypot/copysign/fmod/remainder live in FoundationModule
        // (gated on `import Foundation`). Functions below are interpreter
        // extras — not in Swift's stdlib or Foundation, available always.

        i.registerGlobal(name: "gcd") { args in
            try expectCount(args, 2, "gcd")
            guard case .int(let a) = args[0], case .int(let b) = args[1] else {
                throw RuntimeError.invalid("gcd: arguments must be Int")
            }
            return .int(integerGCD(a, b))
        }
        i.registerGlobal(name: "lcm") { args in
            try expectCount(args, 2, "lcm")
            guard case .int(let a) = args[0], case .int(let b) = args[1] else {
                throw RuntimeError.invalid("lcm: arguments must be Int")
            }
            if a == 0 || b == 0 { return .int(0) }
            return .int(Swift.abs(a / integerGCD(a, b) * b))
        }
        i.registerGlobal(name: "factorial") { args in
            try expectCount(args, 1, "factorial")
            guard case .int(let n) = args[0], n >= 0 else {
                throw RuntimeError.invalid("factorial: argument must be a non-negative Int")
            }
            var r = 1
            for k in 2...Swift.max(2, n) where k <= n { r *= k }
            return .int(r)
        }
        i.registerGlobal(name: "binomial") { args in
            // C(n, k) = n! / (k! · (n-k)!) — multiplicative form to avoid
            // overflow for moderately sized inputs.
            try expectCount(args, 2, "binomial")
            guard case .int(let n) = args[0], case .int(let k) = args[1],
                  n >= 0, k >= 0, k <= n
            else {
                throw RuntimeError.invalid("binomial: requires 0 <= k <= n")
            }
            let kk = Swift.min(k, n - k)
            var r = 1
            for j in 0..<kk { r = r * (n - j) / (j + 1) }
            return .int(r)
        }
    }

    // MARK: - Int methods

    private func registerIntMethods(_ i: Interpreter) {
        i.bridges["Int.signum"] = .method { recv, args in
            try expectNoArgs(args, "Int.signum")
            guard case .int(let n) = recv else { throw badReceiver("Int.signum", recv) }
            return .int(n.signum())
        }
        i.bridges["Int.clamped"] = .method { recv, args in
            // .clamped(to: lo...hi)
            try expectCount(args, 1, "Int.clamped(to:)")
            guard case .int(let n) = recv else { throw badReceiver("Int.clamped(to:)", recv) }
            guard case .range(let lo, let hi, let closed) = args[0] else {
                throw RuntimeError.invalid("Int.clamped(to:): argument must be a Range")
            }
            let upper = closed ? hi : hi - 1
            return .int(Swift.max(lo, Swift.min(upper, n)))
        }
    }

    // MARK: - Double methods

    private func registerDoubleMethods(_ i: Interpreter) {
        i.bridges["Double.clamped"] = .method { recv, args in
            try expectCount(args, 1, "Double.clamped(to:)")
            guard case .double(let d) = recv else { throw badReceiver("Double.clamped(to:)", recv) }
            // Accept either an Int range or an explicit (Double, Double) tuple.
            switch args[0] {
            case .range(let lo, let hi, let closed):
                let upper = Double(closed ? hi : hi)
                return .double(Swift.max(Double(lo), Swift.min(upper, d)))
            default:
                throw RuntimeError.invalid("Double.clamped(to:): argument must be a Range")
            }
        }
        i.bridges["Double.truncatingRemainder"] = .method { recv, args in
            // .truncatingRemainder(dividingBy: y) — proper Swift semantic
            try expectCount(args, 1, "Double.truncatingRemainder(dividingBy:)")
            guard case .double(let x) = recv else { throw badReceiver("Double.truncatingRemainder", recv) }
            let y = try toDouble(args[0])
            return .double(x.truncatingRemainder(dividingBy: y))
        }
        i.bridges["Double.sign"] = .computed { recv in
            // Returns -1.0 / 0.0 / 1.0 — close enough to FloatingPointSign.
            guard case .double(let d) = recv else { throw badReceiver("Double.sign", recv) }
            if d > 0 { return .double(1.0) }
            if d < 0 { return .double(-1.0) }
            return .double(0.0)
        }
    }

    // MARK: - Array reductions

    private func registerArrayReductions(_ i: Interpreter) {
        i.bridges["Array.sum"] = .method { recv, args in
            try expectNoArgs(args, "Array.sum")
            guard case .array(let xs) = recv else { throw badReceiver("Array.sum", recv) }
            if xs.allSatisfy({ if case .int = $0 { return true }; return false }) {
                var s = 0
                for case .int(let n) in xs { s += n }
                return .int(s)
            }
            var s = 0.0
            for v in xs { s += try toDouble(v) }
            return .double(s)
        }
        i.bridges["Array.product"] = .method { recv, args in
            try expectNoArgs(args, "Array.product")
            guard case .array(let xs) = recv else { throw badReceiver("Array.product", recv) }
            if xs.allSatisfy({ if case .int = $0 { return true }; return false }) {
                var s = 1
                for case .int(let n) in xs { s *= n }
                return .int(s)
            }
            var s = 1.0
            for v in xs { s *= try toDouble(v) }
            return .double(s)
        }
        i.bridges["Array.average"] = .method { recv, args in
            try expectNoArgs(args, "Array.average")
            guard case .array(let xs) = recv else { throw badReceiver("Array.average", recv) }
            guard !xs.isEmpty else {
                throw RuntimeError.invalid("Array.average: empty array")
            }
            var s = 0.0
            for v in xs { s += try toDouble(v) }
            return .double(s / Double(xs.count))
        }
    }
}

// MARK: - Helpers

private func expectCount(_ args: [Value], _ n: Int, _ name: String) throws {
    if args.count != n {
        throw RuntimeError.invalid("\(name): expected \(n) argument(s), got \(args.count)")
    }
}

private func expectNoArgs(_ args: [Value], _ name: String) throws {
    if !args.isEmpty {
        throw RuntimeError.invalid("\(name): no arguments expected")
    }
}

private func badReceiver(_ name: String, _ recv: Value) -> Error {
    RuntimeError.invalid("\(name): unexpected receiver \(typeName(recv))")
}

private func integerGCD(_ a: Int, _ b: Int) -> Int {
    var x = Swift.abs(a)
    var y = Swift.abs(b)
    while y != 0 { (x, y) = (y, x % y) }
    return x
}

