// Easy nice-to-haves: array/string slicing via Range<Int>, .indices.
//
// Real Swift's slicing returns `ArraySlice` / `Substring`; we collapse
// to `Array` / `String`, which round-trip through `Array(_:)` and
// `String(_:)` without observable difference at print time.

let xs = [10, 20, 30, 40, 50]

// Closed and half-open range slicing.
print(Array(xs[1..<4]))
print(Array(xs[0...2]))
print(Array(xs[3..<xs.count]))
print(Array(xs[xs.count..<xs.count]))  // empty slice

// Array.indices.
print(xs.indices)
print(Array(xs.indices))

// Iterate by index using indices.
for i in xs.indices {
    print(i, "->", xs[i])
}

// String slicing — script-friendly Int-based.
let s = "hello"
print(String(s.prefix(3)))    // already works
print(String(s.suffix(2)))    // already works
// Swift requires String.Index here, which we don't model. Demonstrate
// only via prefix/suffix to keep the probe portable.
