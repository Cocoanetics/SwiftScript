import Foundation

/// Reference-typed carrier for an asynchronous element source. Bridges
/// host-Swift `AsyncSequence` values into the interpreter's iteration
/// model: a registered builtin creates an `AsyncStreamBox` by capturing
/// a host iterator's `.next()` in the closure, and the for-loop adapter
/// in the interpreter drives it via `try await stream.next()`.
///
/// The box conforms to nothing on its own — it's plumbing — but values
/// flow through the interpreter as `.opaque("AsyncStream", box)`.
public final class AsyncStreamBox: @unchecked Sendable {
    public let next: () async throws -> Value?

    public init(next: @escaping () async throws -> Value?) {
        self.next = next
    }
}
