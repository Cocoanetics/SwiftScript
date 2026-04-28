// Smoke probe for auto-harvested bridges. Each line exercises a method
// or property the generator picked up automatically (no hand-written
// wiring on our side).
import Foundation

// Stdlib numeric: leading/trailing zero counts, byteSwapped, nonzero
// bit count.
print(Int(0).leadingZeroBitCount)
print(Int(8).trailingZeroBitCount)
print(Int(7).nonzeroBitCount)
print(Int(1).byteSwapped < 0)  // single Int reversed is large negative
print(Int.isSigned)

// Double IEEE-754 introspection.
print((1.0).nextUp > 1.0)
print((1.0).nextDown < 1.0)
print(Double.pi.exponent)

// String basic introspection (auto-harvested).
print("hello".isEmpty)
print("hello".count)
print("abc".hashValue == "abc".hashValue)

// CharacterSet set algebra (auto-harvested instance methods). Using
// the explicit `CharacterSet.foo` form because our interpreter doesn't
// yet do contextual typing from let-binding annotations.
let lower = CharacterSet.lowercaseLetters
let upper = CharacterSet.uppercaseLetters
let allLetters = lower.union(upper)
let nonLetters = allLetters.inverted
print(allLetters.isSuperset(of: lower))
print(allLetters.isStrictSuperset(of: lower))
print(allLetters.isDisjoint(with: nonLetters))

// Date constructors not previously hand-listed.
let t = Date(timeIntervalSinceReferenceDate: 0)
print(t.timeIntervalSince1970 < 0)

// UUID round-trip (auto-bridged init from String).
let id = UUID()
print(id.uuidString.count)
let parsed = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
print(parsed.uuidString)
