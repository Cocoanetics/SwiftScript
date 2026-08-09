// Data as a mutable byte buffer: append, subscripts, slices.
import Foundation

var data = Data([1, 2])
data.append(Data([3, 4]))
data.append(contentsOf: [5, 6])
print(data.count)
print(data[0], data[3], data[5])
data[0] = 200
print(data[0])
let slice = data[1..<4]
print(slice.count)
let n32: Int32 = 40
print(n32 + 2)
