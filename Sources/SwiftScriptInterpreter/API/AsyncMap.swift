/// Async-aware variant of `Sequence.map`. The interpreter's eval graph is
/// fully `async throws`, so plain `.map { try await … }` doesn't compile —
/// the stdlib's `map` takes a synchronous transform. This helper bridges
/// that gap without forcing every call site into a manual for-loop.
extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(underestimatedCount)
        for el in self {
            result.append(try await transform(el))
        }
        return result
    }
}
