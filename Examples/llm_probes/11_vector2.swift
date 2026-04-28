struct Vector2 {
    var x: Double
    var y: Double

    func length() -> Double {
        return (x * x + y * y).squareRoot()
    }

    func add(_ other: Vector2) -> Vector2 {
        return Vector2(x: x + other.x, y: y + other.y)
    }

    func scaled(by k: Double) -> Vector2 {
        return Vector2(x: x * k, y: y * k)
    }

    func dot(_ other: Vector2) -> Double {
        return x * other.x + y * other.y
    }
}

let a = Vector2(x: 3, y: 4)
let b = Vector2(x: 1, y: 2)

print(a)
print("|a|     =", a.length())
print("a + b   =", a.add(b))
print("a * 2   =", a.scaled(by: 2))
print("a · b   =", a.dot(b))
