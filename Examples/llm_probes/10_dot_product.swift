func dot(_ a: [Double], _ b: [Double]) -> Double {
    return zip(a, b).map { $0.0 * $0.1 }.reduce(0, +)
}

let u = [1.0, 2.0, 3.0]
let v = [4.0, 5.0, 6.0]
print(dot(u, v))
