func gcd(_ a: Int, _ b: Int) -> Int {
    var x = a
    var y = b
    while y != 0 {
        let t = y
        y = x % y
        x = t
    }
    return x
}

print(gcd(48, 18))
print(gcd(1071, 462))
