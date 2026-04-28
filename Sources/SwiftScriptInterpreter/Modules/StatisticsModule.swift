import Foundation

/// Statistical helpers on `[Double]`-shaped arrays. Hand-written in every
/// LLM analysis script today.
public struct StatisticsModule: BuiltinModule {
    public let name = "Statistics"
    public init() {}

    public func register(into i: Interpreter) {
        i.bridges["Array.median()"] = .method { recv, args in
            guard args.isEmpty else { throw RuntimeError.invalid("Array.median: no arguments") }
            let xs = try numericArray(recv, methodName: "Array.median")
            guard !xs.isEmpty else { throw RuntimeError.invalid("Array.median: empty array") }
            let sorted = xs.sorted()
            let n = sorted.count
            if n % 2 == 1 {
                return .double(sorted[n / 2])
            }
            return .double((sorted[n/2 - 1] + sorted[n/2]) / 2)
        }
        i.bridges["Array.variance()"] = .method { recv, args in
            guard args.isEmpty else { throw RuntimeError.invalid("Array.variance: no arguments") }
            let xs = try numericArray(recv, methodName: "Array.variance")
            guard !xs.isEmpty else { throw RuntimeError.invalid("Array.variance: empty array") }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
            return .double(v)
        }
        i.bridges["Array.stdDev()"] = .method { recv, args in
            guard args.isEmpty else { throw RuntimeError.invalid("Array.stdDev: no arguments") }
            let xs = try numericArray(recv, methodName: "Array.stdDev")
            guard !xs.isEmpty else { throw RuntimeError.invalid("Array.stdDev: empty array") }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
            return .double(v.squareRoot())
        }
        i.bridges["Array.percentile()"] = .method { recv, args in
            // .percentile(0.5) → median-equivalent; linear interpolation
            // between adjacent samples (matches numpy's "linear" method).
            guard args.count == 1 else {
                throw RuntimeError.invalid("Array.percentile: expected 1 argument")
            }
            let p = try toDouble(args[0])
            guard p >= 0, p <= 1 else {
                throw RuntimeError.invalid("Array.percentile: p must be in 0...1")
            }
            let xs = try numericArray(recv, methodName: "Array.percentile")
            guard !xs.isEmpty else { throw RuntimeError.invalid("Array.percentile: empty array") }
            let sorted = xs.sorted()
            let n = sorted.count
            if n == 1 { return .double(sorted[0]) }
            let pos = p * Double(n - 1)
            let i = Int(pos)
            let frac = pos - Double(i)
            if i + 1 >= n { return .double(sorted[i]) }
            return .double(sorted[i] + frac * (sorted[i + 1] - sorted[i]))
        }
    }
}

/// Cast an Array Value to `[Double]`, promoting Int elements. Throws if
/// the receiver isn't an array or contains non-numeric values.
private func numericArray(_ value: Value, methodName: String) throws -> [Double] {
    guard case .array(let xs) = value else {
        throw RuntimeError.invalid("\(methodName): receiver must be an Array")
    }
    return try xs.map { try toDouble($0) }
}
