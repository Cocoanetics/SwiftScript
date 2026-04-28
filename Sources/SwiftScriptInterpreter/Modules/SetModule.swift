import Foundation

/// Stdlib collection constructors that don't fit `registerInit` cleanly
/// because they take closures or sequences (the bridge generator can't
/// model these signatures). Lives here for proximity to `Set` since the
/// idioms are similar. Always-on, no import required.
struct DictionaryModule: BuiltinModule {
    let name = "Dictionary"

    func register(into i: Interpreter) {
        // `Dictionary(uniqueKeysWithValues: [(K, V)])` — build a dict
        // from a sequence of key/value tuples. Throws on duplicate keys
        // (matching Swift's runtime check).
        i.registerInit(on: "Dictionary", labels: ["uniqueKeysWithValues"]) { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Dictionary(uniqueKeysWithValues:): expected 1 argument")
            }
            let pairs = try iterableToArray(args[0])
            var entries: [DictEntry] = []
            for p in pairs {
                guard case .tuple(let elems, _) = p, elems.count == 2 else {
                    throw RuntimeError.invalid(
                        "Dictionary(uniqueKeysWithValues:): each element must be a (key, value) tuple"
                    )
                }
                if entries.contains(where: { $0.key == elems[0] }) {
                    throw RuntimeError.invalid(
                        "Dictionary(uniqueKeysWithValues:): duplicate key \(elems[0])"
                    )
                }
                entries.append(DictEntry(key: elems[0], value: elems[1]))
            }
            return .dict(entries)
        }
        // `Dictionary(grouping: sequence, by: keyFor)` — group elements
        // by the closure's return value. Result type is `[K: [Element]]`.
        // Captures the interpreter weakly so the closure dispatcher (which
        // handles user closures) is available.
        i.registerInit(on: "Dictionary", labels: ["grouping", "by"]) { [weak i] args in
            guard let i else {
                throw RuntimeError.invalid("Dictionary(grouping:by:): interpreter unavailable")
            }
            guard args.count == 2 else {
                throw RuntimeError.invalid("Dictionary(grouping:by:): expected 2 arguments")
            }
            guard case .function(let fn) = args[1] else {
                throw RuntimeError.invalid(
                    "Dictionary(grouping:by:): second argument must be a closure"
                )
            }
            let elements = try iterableToArray(args[0])
            var entries: [DictEntry] = []
            for el in elements {
                let key = try await i.invoke(fn, args: [el])
                if let idx = entries.firstIndex(where: { $0.key == key }) {
                    if case .array(var arr) = entries[idx].value {
                        arr.append(el)
                        entries[idx].value = .array(arr)
                    }
                } else {
                    entries.append(DictEntry(key: key, value: .array([el])))
                }
            }
            return .dict(entries)
        }
    }
}

/// Stdlib `Set` support — always available, no import required.
///
/// Backing: `Value.set([Value])` carries an ordered list of unique values
/// (Equatable-deduped, not Hashable-keyed). Set algebra and member ops
/// dispatch on this case in `Interpreter+Members.swift` /
/// `Interpreter+Calls.swift`. Iteration treats it like an array.
///
/// Construction:
///   - `Set<T>()` / `Set()`               — empty (generic specialization
///     strips at the call site, so `Set<Int>()` reaches `Set()`)
///   - `Set([1, 2, 3])`                   — from an Array
///   - `Set(0..<3)` / `Set(1...5)`        — from a Range
///   - `Set(otherSet)` or `Set(dict.keys)` — from any iterable Value
struct SetModule: BuiltinModule {
    let name = "Set"

    func register(into i: Interpreter) {
        i.registerInit(on: "Set", labels: []) { _ in
            return .set([])
        }
        i.registerInit(on: "Set", labels: ["_"]) { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Set(_:): expected 1 argument")
            }
            // Accept any of the built-in sequence-shaped Values. We dedup
            // by `Value.==` while preserving first-seen order.
            let elements = try iterableToArray(args[0])
            var out: [Value] = []
            out.reserveCapacity(elements.count)
            for v in elements where !out.contains(v) {
                out.append(v)
            }
            return .set(out)
        }
    }
}

/// Convert an iterable Value to an `[Value]`. Used by `Set(_:)` and any
/// other built-in that wants to ingest "a sequence of T" generically.
/// Throws for non-iterable types.
func iterableToArray(_ value: Value) throws -> [Value] {
    switch value {
    case .array(let xs): return xs
    case .set(let xs):   return xs
    case .range(let lo, let hi, let closed):
        let upper = closed ? hi : hi - 1
        guard upper >= lo else { return [] }
        return (lo...upper).map { .int($0) }
    case .dict(let entries):
        // `Set(dict.keys)`-style usage — `dict.keys` already evaluates
        // to a `.array`, so this branch only fires if the user passes
        // the dict directly. Real Swift wouldn't compile, so throw.
        _ = entries
        throw RuntimeError.invalid(
            "expected a sequence, got Dictionary (use `dict.keys` or `dict.values`)"
        )
    case .string(let s):
        // `Array(s)` and `Set(s)` — Swift treats String as a sequence of
        // Character. We don't model Character separately; emit each
        // grapheme cluster as a single-character String, which round-
        // trips through equality.
        return s.map { .string(String($0)) }
    default:
        throw RuntimeError.invalid("expected a sequence, got \(typeName(value))")
    }
}
