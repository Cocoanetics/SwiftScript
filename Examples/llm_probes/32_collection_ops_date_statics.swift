// Easy nice-to-haves: collection compound-assignment operators, Range
// reversed, Date static properties.
import Foundation

// `+=` on Array/String — already works since `+` does and we have
// general compound-assignment lvalue paths.
var arr = [1, 2, 3]
arr += [4, 5]
print(arr)

var s = "hi"
s += " world"
print(s)

// Range.reversed gives a reversed sequence — collapsed to Array.
print(Array((1...5).reversed()))
print(Array((0..<3).reversed()))

// Date.distantFuture / .distantPast / .now (static properties).
print(Date.distantFuture > Date())
print(Date.distantPast < Date())
print(Date.now <= Date.distantFuture)
print(Date.now > Date.distantPast)
