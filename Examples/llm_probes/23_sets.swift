// LLM idiom: deduplicate, set algebra, intersection-based filtering.

let fruits = Set(["apple", "banana", "apple", "cherry", "banana"])
print(fruits.count)
print(fruits.contains("apple"))
print(fruits.contains("durian"))
print(fruits.isEmpty)

// Set algebra. Use sorted() to get deterministic output across both
// runtimes — Swift's Set iteration order is unspecified.
let a: Set<Int> = Set([1, 2, 3, 4])
let b: Set<Int> = Set([3, 4, 5, 6])
print(a.union(b).sorted())
print(a.intersection(b).sorted())
print(a.subtracting(b).sorted())
print(a.symmetricDifference(b).sorted())

print(a.isSubset(of: Set([1, 2, 3, 4, 5])))
print(a.isSuperset(of: Set([1, 2])))
print(a.isDisjoint(with: Set([10, 20])))

// Mutating: insert / remove / formUnion.
var s: Set<Int> = Set([1, 2, 3])
s.insert(4)
s.insert(2) // already there — no-op
s.remove(1)
print(s.sorted())

s.formUnion([10, 20, 4])
print(s.sorted())

s.subtract([20, 99])
print(s.sorted())

// Iteration with for-in. We sort first to keep output stable.
for x in s.sorted() {
    print("- \(x)")
}

// Sequence methods on Set: map -> Array, filter -> Set, reduce.
let doubled = a.map { $0 * 2 }.sorted()
print(doubled)

let evens = a.filter { $0 % 2 == 0 }.sorted()
print(evens)

let sum = a.reduce(0, +)
print(sum)

// Build a Set from a Range.
let r = Set(1...5)
print(r.sorted())
