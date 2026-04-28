class A {
    func greet() -> String { return "A" }
}
class B: A {
    func greet() -> String { return "B" }
}
print(B().greet())
