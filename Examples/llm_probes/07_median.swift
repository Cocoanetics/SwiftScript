func median(_ xs: [Double]) -> Double {
    let sorted = xs.sorted()
    let n = sorted.count
    if n % 2 == 1 {
        return sorted[n / 2]
    }
    return (sorted[n/2 - 1] + sorted[n/2]) / 2
}

print(median([3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0]))
print(median([1.0, 2.0, 3.0]))
