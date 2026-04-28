import Foundation

func solve(_ a: Double, _ b: Double, _ c: Double) -> [Double] {
    let d = b*b - 4*a*c
    if d < 0 { return [] }
    if d == 0 { return [-b / (2*a)] }
    let s = d.squareRoot()
    return [(-b - s) / (2*a), (-b + s) / (2*a)]
}

let roots = solve(1, -5, 6)
for (i, r) in roots.enumerated() {
    print(String(format: "x%d = %.4f", i + 1, r))
}
