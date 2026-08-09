// `as?` must unwrap Optional layers the way stock Swift's dynamic
// cast does — `dict["k"] as? Int` yields the boxed Int, and casts
// check collection element types instead of shapes.
let dict: [String: Any] = ["n": 1, "s": "one", "list": [1, 2, 3]]
print(dict["n"] as? Int)
print(dict["n"] as? String)
print(dict["s"] as? String)
print(dict["missing"] as? Int)
print(dict["list"] as? [Int])
print(dict["list"] as? [String])

let anyArray: [Any] = ["a", "b"]
print(anyArray as? [Int])
print(anyArray as? [String])

let maybe: Int? = 7
print(maybe as? Int)
let none: Int? = nil
print(none as? Int)

func describe(_ x: Any) -> String {
    switch x {
    case let i as Int: return "int \(i)"
    case let s as String: return "string \(s)"
    case is [Int]: return "int array"
    default: return "other"
    }
}
print(describe(5))
print(describe("hi"))
print(describe([1, 2]))
print(describe(dict["n"] as Any))
