// LLM idiom: a generic Stack used with a small algorithm.
// Reverse a list using a stack.

struct Stack<T> {
    var items: [T] = []

    mutating func push(_ x: T) { items.append(x) }
    mutating func pop() -> T { items.removeLast() }
    var isEmpty: Bool { items.isEmpty }
}

func reversed<T>(_ xs: [T]) -> [T] {
    var s = Stack<T>()
    for x in xs { s.push(x) }
    var out: [T] = []
    while !s.isEmpty { out.append(s.pop()) }
    return out
}

print(reversed([1, 2, 3, 4, 5]))
print(reversed(["alpha", "beta", "gamma"]))
