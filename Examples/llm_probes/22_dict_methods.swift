// LLM idiom: rich dict transformations.

let prices = ["apple": 1, "banana": 2, "cherry": 3]

// mapValues — transform each value, keep keys.
let cents = prices.mapValues { $0 * 100 }
for (k, v) in cents.sorted(by: { $0.key < $1.key }) {
    print(k, v)
}

// compactMapValues — drop nils, keep the rest.
let parsed = ["a": "1", "b": "two", "c": "3"].compactMapValues { Int($0) }
for (k, v) in parsed.sorted(by: { $0.key < $1.key }) {
    print(k, v)
}

// filter — keep entries matching predicate, returns dict.
let cheap = prices.filter { $0.value < 3 }
print(cheap.count, "cheap items")

// reduce — fold over (k, v) pairs.
let total = prices.reduce(0) { acc, pair in acc + pair.value }
print("total:", total)

// merging — combine with conflict resolver.
let extra = ["banana": 5, "date": 4]
let merged = prices.merging(extra, uniquingKeysWith: { old, new in old + new })
for (k, v) in merged.sorted(by: { $0.key < $1.key }) {
    print(k, v)
}

// dict[k, default: v] — use fallback when key missing.
let counts = ["a": 3, "b": 1]
print(counts["a", default: 0])
print(counts["z", default: 0])

// removeValue(forKey:) — mutating, returns Optional<V>.
var live = prices
let removed = live.removeValue(forKey: "banana")
print(removed ?? -1)
print(live.count)
let absent = live.removeValue(forKey: "nope")
print(absent ?? -1)
