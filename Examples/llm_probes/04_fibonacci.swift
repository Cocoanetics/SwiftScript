func fib(_ n: Int) -> Int {
    if n <= 1 { return n }
    var a = 0
    var b = 1
    for _ in 0..<n-1 {
        let next = a + b
        a = b
        b = next
    }
    return b
}

let result = (0..<10).map(fib)
print(result)
