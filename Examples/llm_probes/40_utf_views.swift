// String code-unit views must report code units, not Characters —
// "héllo".utf8.count is 6 in stock Swift (é is two UTF-8 bytes).
import Foundation

let s = "héllo"
print(s.count)
print(s.utf8.count)
print(s.utf16.count)
print(s.unicodeScalars.count)
print(Array(s.utf8))
let flag = "🇦🇷"
print(flag.count, flag.utf8.count, flag.utf16.count, flag.unicodeScalars.count)
let data = Data(s.utf8)
print(data.count)
print(String(data: data, encoding: .utf8)!)
var byteSum = 0
for b in "abc".utf8 {
    byteSum += Int(b)
}
print(byteSum)
for u in "é".unicodeScalars {
    print(u.value)
}
