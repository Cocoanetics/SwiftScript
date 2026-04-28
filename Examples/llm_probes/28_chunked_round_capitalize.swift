// Easy nice-to-haves: capitalization, exact numeric conversion,
// rounding rules with implicit member shorthand.
//
// `Array.chunked(into:)` is a popular LLM idiom but lives in Swift
// Algorithms (not stdlib), so we leave it out of the auto-bridges to
// preserve strict swiftc parity.
import Foundation

// String.capitalized — Foundation property.
print("hello world".capitalized)
print("HELLO".capitalized)

// Int(exactly:) / Double(exactly:).
print(Int(exactly: 3.0) ?? -1)
print(Int(exactly: 3.5) ?? -1)
print(Double(exactly: 42) ?? -1.0)

// Double.rounded(_ rule:) — explicit and implicit member.
let d = 3.5
print(d.rounded())                                        // 4.0 (toNearestOrEven rule's tie -> even, but 3.5 -> 4 here)
print(d.rounded(FloatingPointRoundingRule.up))            // 4.0
print(d.rounded(.up))                                      // 4.0
print((2.5).rounded(.toNearestOrEven))                    // 2.0 (banker's)
print((-1.5).rounded(.towardZero))                        // -1.0
print((1.7).rounded(.down))                               // 1.0
