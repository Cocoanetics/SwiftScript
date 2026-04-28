// Easy nice-to-haves: Array.swapAt + split, String.padding +
// percent-encoding, more harvest from the Foundation symbol graph.
import Foundation

// Array.swapAt(_:_:) — mutating.
var xs = [10, 20, 30, 40]
xs.swapAt(0, 3)
print(xs)

// Array.split(separator:) on element values.
let parts = [1, 2, 0, 3, 4, 0, 5].split(separator: 0)
print(parts.map { Array($0) })

// String.padding — Foundation.
print("hi".padding(toLength: 5, withPad: "-", startingAt: 0))
print("longer".padding(toLength: 4, withPad: "x", startingAt: 0))
print("a".padding(toLength: 6, withPad: "ab", startingAt: 0))

// Percent-encoding — common URL-building idiom.
print("hello world".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
print("hello%20world".removingPercentEncoding ?? "")
