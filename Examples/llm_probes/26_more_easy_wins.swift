// More easy nice-to-haves: Array conversions, String(repeating:count:),
// shuffled (verified via sort-and-compare), mutating sort/reverse/removeAll,
// elementsEqual.

let set: Set<Int> = Set([3, 1, 2])
print(Array(set).sorted())
print(Array(1...5))
print(Array("abc"))

// String(repeating:count:).
print(String(repeating: "ab", count: 3))
print(String(repeating: "-", count: 0))

// Shuffled — same multiset of elements when re-sorted.
let xs = [1, 2, 3, 4, 5]
print(xs.shuffled().sorted() == xs)

// removeAll(where:) — mutating.
var nums = [1, 2, 3, 4, 5, 6]
nums.removeAll(where: { $0 % 2 == 0 })
print(nums)

// sort() and reverse() — mutating.
var rev = [3, 1, 2]
rev.sort()
print(rev)
rev.reverse()
print(rev)

// removeAll() — clear in place.
var letters = ["a", "b", "c"]
letters.removeAll()
print(letters.isEmpty)

// elementsEqual.
print([1, 2, 3].elementsEqual([1, 2, 3]))
print([1, 2, 3].elementsEqual([1, 2, 4]))

// Bool.random — call site succeeds and returns Bool. Suppress randomness
// by checking the value space.
let coin = Bool.random()
print(coin == true || coin == false)
