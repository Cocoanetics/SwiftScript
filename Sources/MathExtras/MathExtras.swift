// MathExtras — small math/stats helpers commonly hand-rolled in Swift
// scripts. Distributed as a real Swift library so the same source can be
// used by both stock `swift` (via the prebuilt module + library) and
// `swift-script` (which recognizes `import MathExtras` and registers the
// equivalent functions in its bridge table).
import Foundation

// MARK: - Number theory

public func gcd(_ a: Int, _ b: Int) -> Int {
    var x = Swift.abs(a)
    var y = Swift.abs(b)
    while y != 0 { (x, y) = (y, x % y) }
    return x
}

public func lcm(_ a: Int, _ b: Int) -> Int {
    if a == 0 || b == 0 { return 0 }
    return Swift.abs(a / gcd(a, b) * b)
}

public func factorial(_ n: Int) -> Int {
    precondition(n >= 0, "factorial: argument must be non-negative")
    var r = 1
    if n >= 2 { for k in 2...n { r *= k } }
    return r
}

public func binomial(_ n: Int, _ k: Int) -> Int {
    precondition(n >= 0 && k >= 0 && k <= n, "binomial: requires 0 <= k <= n")
    let kk = Swift.min(k, n - k)
    var r = 1
    for j in 0..<kk { r = r * (n - j) / (j + 1) }
    return r
}

// MARK: - Clamping

extension Int {
    public func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
    public func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound - 1, self))
    }
}

extension Double {
    public func clamped(to range: ClosedRange<Int>) -> Double {
        Swift.max(Double(range.lowerBound), Swift.min(Double(range.upperBound), self))
    }
    public func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

// MARK: - Array reductions

extension Array where Element == Int {
    public func sum() -> Int { reduce(0, +) }
    public func product() -> Int { reduce(1, *) }
}

extension Array where Element == Double {
    public func sum() -> Double { reduce(0, +) }
    public func product() -> Double { reduce(1, *) }

    public func average() -> Double {
        precondition(!isEmpty, "average: empty array")
        return reduce(0, +) / Double(count)
    }

    public func median() -> Double {
        precondition(!isEmpty, "median: empty array")
        let s = sorted()
        let n = s.count
        if n.isMultiple(of: 2) { return (s[n/2 - 1] + s[n/2]) / 2 }
        return s[n / 2]
    }

    public func variance() -> Double {
        precondition(!isEmpty, "variance: empty array")
        let m = average()
        return reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(count)
    }

    public func stdDev() -> Double { variance().squareRoot() }

    /// Linear-interpolated percentile (numpy "linear" method). `p` in 0...1.
    public func percentile(_ p: Double) -> Double {
        precondition(p >= 0 && p <= 1, "percentile: p must be in 0...1")
        precondition(!isEmpty, "percentile: empty array")
        let s = sorted()
        let n = s.count
        if n == 1 { return s[0] }
        let pos = p * Double(n - 1)
        let i = Int(pos)
        let frac = pos - Double(i)
        if i + 1 >= n { return s[i] }
        return s[i] + frac * (s[i + 1] - s[i])
    }
}
