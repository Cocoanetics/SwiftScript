// Run with: swift run swift-script Examples/math_demo.swift

// --- Quadratic formula, roots returned as an array (empty if complex) -----

func solveQuadratic(_ a: Double, _ b: Double, _ c: Double) -> [Double] {
    let disc = b*b - 4.0*a*c
    if disc < 0.0  { return [] }
    if disc == 0.0 { return [-b / (2.0*a)] }
    let s = sqrt(disc)
    return [(-b + s) / (2.0*a), (-b - s) / (2.0*a)]
}

print("=== quadratic ===")
print("x^2 - 5x + 6 = 0  →", solveQuadratic(1.0, -5.0, 6.0))
print("x^2 + 1     = 0  →", solveQuadratic(1.0, 0.0, 1.0))

// --- Newton's method for sqrt, compared with Foundation -------------------

func newtonSqrt(_ x: Double) -> Double {
    var guess = x / 2.0
    var i = 0
    while i < 50 {
        let next = (guess + x/guess) / 2.0
        if abs(next - guess) < 1e-12 { return next }
        guess = next
        i = i + 1
    }
    return guess
}

print("\n=== sqrt(2) ===")
print("Foundation:", sqrt(2.0))
print("Newton:    ", newtonSqrt(2.0))

// --- Stats over an array -------------------------------------------------

func sum(_ xs: [Double]) -> Double {
    var s = 0.0
    for x in xs { s = s + x }
    return s
}

func mean(_ xs: [Double]) -> Double { sum(xs) / Double(xs.count) }

func variance(_ xs: [Double]) -> Double {
    let m = mean(xs)
    var acc = 0.0
    for x in xs { acc = acc + (x - m) * (x - m) }
    return acc / Double(xs.count)
}

let data = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
print("\n=== stats ===")
print("data:", data)
print("mean:    ", mean(data))
print("variance:", variance(data))
print("stddev:  ", sqrt(variance(data)))

// --- Higher-order: trapezoidal integration of any (Double) -> Double -----

func integrate(_ f: (Double) -> Double, from a: Double, to b: Double, steps: Int) -> Double {
    let dx = (b - a) / Double(steps)
    var s = 0.5 * (f(a) + f(b))
    var i = 1
    while i < steps {
        s = s + f(a + Double(i) * dx)
        i = i + 1
    }
    return s * dx
}

func square(_ x: Double) -> Double { x * x }

print("\n=== ∫₀¹ x² dx ≈ 1/3 ===")
print("trapezoidal:", integrate(square, from: 0.0, to: 1.0, steps: 1000))

print("\n=== ∫₀^π sin(x) dx ≈ 2 ===")
print("trapezoidal:", integrate(sin, from: 0.0, to: pi, steps: 1000))

// --- Primes by trial division, accumulated functionally -------------------

func isPrime(_ n: Int) -> Bool {
    if n < 2 { return false }
    if n == 2 { return true }
    if n % 2 == 0 { return false }
    var i = 3
    while i * i <= n {
        if n % i == 0 { return false }
        i = i + 2
    }
    return true
}

var primes: [Int] = []
for n in 2...50 where isPrime(n) {
    primes = primes + [n]
}
print("\n=== primes ≤ 50 ===")
print(primes)

// --- Fibonacci, switching on size ----------------------------------------

func fib(_ n: Int) -> Int {
    switch n {
    case 0...1: return n
    default:    return fib(n-1) + fib(n-2)
    }
}

print("\n=== fib(0..<10) ===")
for i in 0..<10 {
    print("fib(\(i)) =", fib(i))
}
