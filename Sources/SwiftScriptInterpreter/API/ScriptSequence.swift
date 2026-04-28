import Foundation

/// `Sequence` adapter for any iterable `Value`. Wrapping a script
/// array / set / dict / string / range gives host-Swift code something
/// it can iterate, pass to `Array(_:)`, `Set(_:)`, `zip`, `prefix`, and
/// the rest of the stdlib's sequence-algorithm surface — all elements
/// surfaced as `Value`.
///
/// Two main uses:
/// - **Internal helpers**: bridge code that needs to walk a `Value` no
///   longer has to switch on every shape; it just builds a
///   `ScriptSequence(value)` and uses `for` / `.map` / `.reduce`.
/// - **Outbound bridging**: host functions that take `some Sequence`
///   accept a `ScriptSequence` directly. The `Element` is `Value`, so
///   callers who want a typed array map across `intValue` / `stringValue`
///   etc. before handing on.
public struct ScriptSequence: Sequence {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func makeIterator() -> Iterator {
        Iterator(state: makeState(for: value))
    }

    /// Underlying iteration state, kept opaque so we don't expose the
    /// runtime's iteration shape to callers.
    public struct Iterator: IteratorProtocol {
        var state: IteratorState

        public mutating func next() -> Value? {
            state.next()
        }
    }

    /// True if the wrapped value is iterable in our model.
    public static func isIterable(_ value: Value) -> Bool {
        switch value {
        case .array, .set, .dict, .string, .range: return true
        case .opaque("TaskGroup", _):              return true
        default: return false
        }
    }
}

/// Lightweight value-typed iterator state. Concrete shapes are inlined
/// here so we don't allocate an erased iterator on the heap per call.
public enum IteratorState {
    case array(IndexingIterator<[Value]>)
    case range(Int, end: Int)        // half-open [lo, end)
    case characters(String.Iterator)
    case dict(IndexingIterator<[DictEntry]>)
    case taskGroup(IndexingIterator<[Value]>)
    case empty

    mutating func next() -> Value? {
        switch self {
        case .array(var it):
            let v = it.next(); self = .array(it); return v
        case .range(let cur, let end):
            if cur >= end { self = .empty; return nil }
            self = .range(cur + 1, end: end)
            return .int(cur)
        case .characters(var it):
            guard let c = it.next() else { self = .empty; return nil }
            self = .characters(it)
            return .string(String(c))
        case .dict(var it):
            guard let entry = it.next() else { self = .empty; return nil }
            self = .dict(it)
            return .tuple([entry.key, entry.value], labels: ["key", "value"])
        case .taskGroup(var it):
            let v = it.next(); self = .taskGroup(it); return v
        case .empty:
            return nil
        }
    }
}

private func makeState(for value: Value) -> IteratorState {
    switch value {
    case .array(let xs):  return .array(xs.makeIterator())
    case .set(let xs):    return .array(xs.makeIterator())
    case .string(let s):  return .characters(s.makeIterator())
    case .dict(let es):   return .dict(es.makeIterator())
    case .range(let lo, let hi, let closed):
        return .range(lo, end: closed ? hi + 1 : hi)
    case .opaque("TaskGroup", let box):
        if let group = box as? TaskGroupBox {
            return .taskGroup(group.results.makeIterator())
        }
        return .empty
    default:
        return .empty
    }
}

// MARK: - Convenience iteration accessors on Value

extension Value {
    /// Iterate this value as a sequence of `Value` elements. Throws if
    /// the value isn't iterable.
    public func asSequence() throws -> ScriptSequence {
        guard ScriptSequence.isIterable(self) else {
            throw RuntimeError.invalid("not iterable: \(typeName(self))")
        }
        return ScriptSequence(self)
    }

    /// Materialize the value as a `[Value]` array. Convenient for
    /// bridge code that needs to build a concrete array but doesn't
    /// care about the source shape.
    public func toArray() throws -> [Value] {
        Array(try asSequence())
    }
}
