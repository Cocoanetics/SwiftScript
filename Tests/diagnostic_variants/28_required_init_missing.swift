class A {
    required init() { print("A.init") }
}
class B: A {
    init(x: Int) {
        super.init()
    }
}
