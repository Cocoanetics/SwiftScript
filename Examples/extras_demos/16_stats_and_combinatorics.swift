// Mix of MathExtras + Statistics modules — the kind of script an analyst
// would write when asked "summarize this data and compute a few helpers".
// (gcd, factorial, binomial, median, etc. are emulated extras — Swift's
// stdlib doesn't ship them — so this script intentionally won't run as
// pure `swift -`. swift-script handles it.)

let data = [4.0, 2.0, 5.0, 8.0, 1.0, 9.0, 3.0]

print("count:    ", data.count)
print("sum:      ", data.sum())
print("average:  ", data.average())
print("median:   ", data.median())
print("variance: ", data.variance())
print("stdDev:   ", data.stdDev())
print("p90:      ", data.percentile(0.9))

// Number theory
print("gcd(48,18) =", gcd(48, 18))
print("lcm(6, 8)  =", lcm(6, 8))
print("5!         =", factorial(5))
print("C(10, 3)   =", binomial(10, 3))

// Pythagorean / clamping
print("hypot(3,4) =", hypot(3.0, 4.0))
print("clamp 15 in 0...10 =", 15.clamped(to: 0...10))
print("(-7).signum()      =", (-7).signum())
