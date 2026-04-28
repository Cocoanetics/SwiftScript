// Tuple-returning bridges: `Int.quotientAndRemainder(dividingBy:)`,
// `Int.addingReportingOverflow(_:)`. The auto-bridge wraps the Swift
// tuple in our `Value.tuple([...])` and tuple destructuring works.

let qr = (17).quotientAndRemainder(dividingBy: 5)
print(qr.0, qr.1)

let (q, r) = (23).quotientAndRemainder(dividingBy: 7)
print(q, r)

// Int.addingReportingOverflow returns (Int, Bool).
let ok = (5).addingReportingOverflow(3)
print(ok.0, ok.1)

let big = Int.max.addingReportingOverflow(1)
print(big.0 < 0, big.1)  // overflow wraps to Int.min

// Int.multipliedFullWidth — (Int, UInt) but UInt isn't bridged, so it
// won't be in our bridge table. Just make sure quotientAndRemainder /
// addingReportingOverflow don't leak.

// Locale equality auto-derived from Equatable conformance.
import Foundation
let a = Locale.current
let b = Locale.current
print(a == b)
