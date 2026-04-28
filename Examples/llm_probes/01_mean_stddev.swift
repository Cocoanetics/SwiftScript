import Foundation

let data = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
let n = Double(data.count)
let mean = data.reduce(0, +) / n
let variance = data.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
let stddev = variance.squareRoot()

print(String(format: "mean:    %.4f", mean))
print(String(format: "stddev:  %.4f", stddev))
