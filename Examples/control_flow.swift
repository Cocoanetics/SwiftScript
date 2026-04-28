// Run with: swift run swift-script Examples/control_flow.swift

let names = ["alice", "bob", "carol", "dave"]

print("everyone:", names.joined(separator: ", "))

for name in names where name.hasPrefix("c") {
    print("matches c-:", name.uppercased())
}

func bucket(_ n: Int) -> String {
    switch n {
    case 0..<10:    return "single digit"
    case 10..<100:  return "two digit"
    case 100...999: return "three digit"
    default:        return "huge"
    }
}

for n in [3, 27, 514, 9999] {
    print(n, "→", bucket(n))
}

func half(_ n: Int) -> Int {
    guard n > 0 else { return -1 }
    return n / 2
}

print("half(20) =", half(20))
print("half(-3) =", half(-3))

outer: for i in 1...3 {
    for j in 1...3 {
        if i * j > 4 { break outer }
        print("\(i)*\(j) =", i * j)
    }
}
