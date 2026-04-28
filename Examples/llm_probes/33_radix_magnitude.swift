// Easy nice-to-haves: radix-based String <-> Int conversions, magnitude
// as property, signum() and clamping idioms via stdlib.

// String(_:radix:) — print as hex/binary/octal.
print(String(255, radix: 16))
print(String(255, radix: 2))
print(String(8, radix: 8))
print(String(10, radix: 16, uppercase: true))
print(String(0, radix: 16))

// Int(_:radix:) — parse from hex/binary, returns Optional.
print(Int("ff", radix: 16) ?? -1)
print(Int("1010", radix: 2) ?? -1)
print(Int("zzz", radix: 16) ?? -1)
print(Int("FE", radix: 16) ?? -1)

// magnitude as property (was previously method-only).
print((-5).magnitude)
print((-3.14).magnitude)
print((3.14).magnitude)
