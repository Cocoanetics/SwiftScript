// Heterogeneous array literals and runtime type casts now match swiftc.
//
//   let arr = ["abc", 1]               // rejected by both
//   let arr: [Any] = ["abc", 1]        // accepted by both
//   x as? T / x as! T / x is T         // both work
//
// We can't probe the rejection directly here (the script wouldn't run),
// so we exercise the accepted forms.

let mixed: [Any] = ["abc", 1, 3.14, true, "tail"]
print(mixed.count)

for x in mixed {
    if let s = x as? String { print("string:", s) }
    else if let i = x as? Int { print("int:", i) }
    else if let d = x as? Double { print("double:", d) }
    else if let b = x as? Bool { print("bool:", b) }
    else { print("other:", x) }
}

// `is` returns Bool.
print(mixed[0] is String)
print(mixed[1] is Int)
print(mixed[1] is String)

// `as!` succeeds on a match.
let asString = mixed[0] as! String
print(asString.uppercased())

// Int/Double homogeneity — Swift coerces, both sides accept.
let nums = [1, 2.0, 3]
print(nums.reduce(0.0, +))
