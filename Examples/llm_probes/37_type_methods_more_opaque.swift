// Auto-harvested static type methods + new opaque types.
import Foundation

// `Double.minimum` / `Double.maximum` — static type methods that take
// two Self params and return Self.
print(Double.minimum(3.0, 5.0))
print(Double.maximum(3.0, 5.0))
print(Double.minimum(-1.5, 2.5))

// `Bool.random()` — static type method, no args.
let coin = Bool.random()
print(coin == true || coin == false)

// `Date()` defaults to "now". `Date.now` is a static property too.
let d = Date()
print(d <= Date.now || Date.now <= d)  // both <= are valid for ~simultaneous

// `Locale.current` — opaque static. Equality auto-bridged from the
// `Equatable` conformance harvested from the symbol graph.
let loc = Locale.current
print(loc == loc)
print(loc == Locale.current)
