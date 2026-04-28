// Round-trip the easy nice-to-haves: array index methods, optional map,
// dict constructors, string niceties.

// Array.firstIndex(of:) / firstIndex(where:) / lastIndex(...).
let xs = [10, 20, 30, 40, 30, 20]
print(xs.firstIndex(of: 30) ?? -1)
print(xs.lastIndex(of: 30) ?? -1)
print(xs.firstIndex(where: { $0 > 25 }) ?? -1)
print(xs.lastIndex(where: { $0 < 25 }) ?? -1)
print(xs.firstIndex(of: 99) ?? -1)

// Array.starts(with:).
print([1, 2, 3, 4].starts(with: [1, 2]))
print([1, 2, 3, 4].starts(with: [2, 3]))

// String.reversed() — wrap in String() since Swift's bare `.reversed()`
// returns `ReversedCollection<String>` (verbose) and scripts always
// re-stringify it.
print(String("hello".reversed()))
print("https://example.com".starts(with: "https"))
print("https://example.com".starts(with: "ftp"))

// Optional.map / flatMap. The flatMap shape uses `Int(_:)` from String
// which returns `Int?` — closer to a real LLM idiom than constructing
// Optional<T>.
let some: Int? = 5
let none: Int? = nil
print(some.map { $0 * 2 } ?? -1)
print(none.map { $0 * 2 } ?? -1)

let strSome: String? = "42"
let strNone: String? = "not a number"
print(strSome.flatMap { Int($0) } ?? -1)
print(strNone.flatMap { Int($0) } ?? -1)

// Dictionary(uniqueKeysWithValues:) — from sequence of pairs.
let pairs = [("a", 1), ("b", 2), ("c", 3)]
let dict = Dictionary(uniqueKeysWithValues: pairs)
for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
    print(k, v)
}

// Dictionary(grouping:by:) — group by closure.
let words = ["apple", "ant", "banana", "blueberry", "cherry"]
let byInitial = Dictionary(grouping: words, by: { String($0.prefix(1)) })
for (k, v) in byInitial.sorted(by: { $0.key < $1.key }) {
    print(k, "->", v.joined(separator: ","))
}
