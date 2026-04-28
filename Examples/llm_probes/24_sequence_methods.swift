// LLM idiom: chained Sequence methods on Range, Set, Array.

// Range.map / .filter / .reduce.
let squares = (1...5).map { $0 * $0 }
print(squares)

let evens = (1...10).filter { $0 % 2 == 0 }
print(evens)

let sum = (1...100).reduce(0, +)
print(sum)

(1...3).forEach { print("step \($0)") }

// Range.prefix / .dropFirst.
print(Array((1...5).prefix(3)))
print(Array((1...5).dropFirst(2)))

// Array.flatMap — concat per-element arrays.
let pairs = [1, 2, 3].flatMap { [$0, $0 * 10] }
print(pairs)

// Set.map -> Array. We sort to get stable output.
let s: Set<Int> = Set([1, 2, 3])
print(s.map { $0 * 2 }.sorted())

// Set.filter -> Set. We sort to compare.
print(s.filter { $0 > 1 }.sorted())

// Mixed: build a Set, transform via map, filter back to a Set on Range.
let r = (1...10)
let positives = r.filter { $0 > 5 }.map { $0 * 100 }
print(positives)
