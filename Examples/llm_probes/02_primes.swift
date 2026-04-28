func isPrime(_ n: Int) -> Bool {
    if n < 2 { return false }
    if n < 4 { return true }
    if n % 2 == 0 { return false }
    var i = 3
    while i * i <= n {
        if n % i == 0 { return false }
        i += 2
    }
    return true
}

let primes = (2..<50).filter(isPrime)
print(primes)
