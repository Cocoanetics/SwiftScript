// Easy nice-to-haves: predicate forms, numeric methods, more Set+Dict
// Sequence-style closures, Range.first(where:).

// Array.first(where:) and last(where:).
let xs = [3, 7, 1, 9, 4, 6]
print(xs.first(where: { $0 > 5 }) ?? -1)
print(xs.last(where: { $0 < 5 }) ?? -1)
print(xs.first(where: { $0 > 100 }) ?? -1)

// Array.contains predicate vs value form.
print([1, 2, 3].contains(2))
print([1, 2, 3].contains(where: { $0 > 2 }))

// Set predicate forms.
let s = Set([1, 2, 3, 4, 5])
print(s.allSatisfy { $0 > 0 })
print(s.allSatisfy { $0 > 3 })
print(s.contains(where: { $0 == 4 }))
print(s.min() ?? -1)
print(s.max() ?? -1)

// Dict predicate forms.
let d = ["a": 1, "b": 2, "c": 3]
print(d.allSatisfy { $0.value > 0 })
let firstBig = d.first(where: { $0.value > 1 })
// Order isn't guaranteed; check membership instead of literal.
if let pair = firstBig {
    print(pair.key == "b" || pair.key == "c")
} else {
    print(false)
}

// Range.first(where:).
print((1...10).first(where: { $0 % 4 == 0 }) ?? -1)

// Numeric: Int.signum, Double.truncatingRemainder, Double.remainder.
print(5.signum())
print((-3).signum())
print(0.signum())
print(7.5.truncatingRemainder(dividingBy: 2.0))
print(7.0.remainder(dividingBy: 3.0))
