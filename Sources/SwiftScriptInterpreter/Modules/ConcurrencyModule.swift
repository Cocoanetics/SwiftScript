import Foundation

/// Async/await runtime shim. The interpreter's eval graph is fully
/// `async throws`, so script `await someBuiltin()` lands on Swift's
/// real concurrency runtime — bridged async builtins (e.g. `sleep`,
/// `URLSession.shared.data`) genuinely suspend and resume.
///
/// `Task { … }` and `withTaskGroup` still execute their bodies inline:
/// the interpreter mutates shared state (scopes, classDefs, …) that
/// isn't `Sendable`, so spawning real concurrent Swift `Task`s would
/// race. Inline execution + real await on leaves passes the Swift
/// Tour deterministically and lets bridged async APIs work.
struct ConcurrencyModule: BuiltinModule {
    let name = "Concurrency"

    func register(into i: Interpreter) {
        // `Task { … }` — runs the trailing closure synchronously and
        // returns a `.void` placeholder. Real Swift returns a Task<…>
        // handle you can `.value` on, but the tour only fires-and-
        // forgets so we leave that surface unimplemented.
        i.registerBuiltin(name: "Task") { args in
            guard args.count == 1, case .function(let fn) = args[0] else {
                throw RuntimeError.invalid("Task: expected a closure")
            }
            _ = try await i.invoke(fn, args: [])
            return .void
        }

        // `sleep(seconds: Double)` — genuinely suspends the calling task
        // via `Task.sleep`. Demonstrates that `await` on a script-side
        // call propagates through the interpreter's async eval graph
        // and lands on Swift's real concurrency runtime.
        i.registerBuiltin(name: "sleep") { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("sleep(seconds:): expected 1 argument")
            }
            let seconds: Double
            switch args[0] {
            case .int(let i):    seconds = Double(i)
            case .double(let d): seconds = d
            default:
                throw RuntimeError.invalid("sleep(seconds:): argument must be Int or Double")
            }
            let nanos = UInt64(max(0, seconds * 1_000_000_000))
            try await Task.sleep(nanoseconds: nanos)
            return .void
        }

        // `withTaskGroup(of: T.self) { group in body }` — runs the body
        // with a fresh task-group opaque, then returns whatever the
        // body returns. `addTask` and `for await` operate on the same
        // group object; tasks run inline (synchronously) when added.
        i.registerBuiltin(name: "withTaskGroup") { [weak i] args in
            guard let i else {
                throw RuntimeError.invalid("withTaskGroup: interpreter unavailable")
            }
            // Trailing closure becomes the second positional arg; the
            // first is the metatype expression `T.self`, which we
            // ignore (we don't track element types).
            guard args.count >= 1, case .function(let fn) = args.last else {
                throw RuntimeError.invalid("withTaskGroup: expected a body closure")
            }
            let group = TaskGroupBox()
            let groupValue = Value.opaque(typeName: "TaskGroup", value: group)
            return try await i.invoke(fn, args: [groupValue])
        }

        // `group.addTask { … }` — runs the closure now, appends the
        // result onto the group's queue. Subsequent `for await` reads
        // them in insertion order.
        i.bridges["TaskGroup.addTask"] = .method { [weak i] receiver, args in
            guard let i else {
                throw RuntimeError.invalid("TaskGroup.addTask: interpreter unavailable")
            }
            guard case .opaque(_, let box) = receiver,
                  let group = box as? TaskGroupBox
            else {
                throw RuntimeError.invalid("TaskGroup.addTask: bad receiver")
            }
            guard args.count == 1, case .function(let fn) = args[0] else {
                throw RuntimeError.invalid("TaskGroup.addTask: expected a closure")
            }
            let result = try await i.invoke(fn, args: [])
            group.results.append(result)
            return .void
        }
    }
}

/// Reference holder for a TaskGroup's accumulated results. Boxed in a
/// `.opaque` Value so ordinary member-access dispatch finds the
/// extension methods registered above. A class (not a struct) so
/// mutations through one Value reach iterators holding another.
final class TaskGroupBox {
    var results: [Value] = []
}
