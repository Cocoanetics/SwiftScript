// Easy nice-to-haves: diagnostic builtins (success path), print
// separator/terminator overrides, String.contains(where:), more
// numeric statics. Failed `assert`/`fatalError` paths trap the
// process in real Swift and aren't comparable, so we only exercise
// the no-fire branches here.

// print with separator: and terminator:.
print(1, 2, 3, separator: " | ")
print("a", "b", "c", separator: ",", terminator: ";\n")
print()  // empty newline still works

// Numeric statics from the regenerated bridges.
print(Int.zero)
print(Double.zero)
print(Int.bitWidth)
print(Double.radix)

// Instance form of bitWidth.
print(42.bitWidth)

// String.contains(where:) — predicate.
print("Hello".contains(where: { $0 == "e" }))
print("Hello".contains(where: { c in c == "z" }))

// assert / precondition — pass without firing. They return Void; we
// just verify they don't throw.
assert(1 + 1 == 2)
precondition(true, "this is fine")
print("assertions ok")
