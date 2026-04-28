import Foundation

// Simpson's rule for ∫ f(x) dx from a to b with n (even) subintervals.
func simpson(_ f: (Double) -> Double, from a: Double, to b: Double, n: Int) -> Double {
    let h = (b - a) / Double(n)
    var s = f(a) + f(b)
    for i in 1..<n {
        let x = a + Double(i) * h
        s += (i % 2 == 0 ? 2.0 : 4.0) * f(x)
    }
    return s * h / 3
}

let area = simpson({ $0 * $0 }, from: 0, to: 1, n: 100)
print(String(format: "%.6f", area))
