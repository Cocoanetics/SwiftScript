import SwiftSyntax

extension Interpreter {
    func evaluate(memberAccess: MemberAccessExprSyntax, in scope: Scope) async throws -> Value {
        if startsOptionalChain(ExprSyntax(memberAccess)) {
            return try await evaluateInOptionalChain(ExprSyntax(memberAccess), in: scope)
        }
        guard let base = memberAccess.base else {
            throw RuntimeError.unsupported(
                "implicit member access (\(memberAccess.declName.baseName.text))",
                at: memberAccess.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        // Static member: `Int.max`, `Double.pi`, …
        if let ref = base.as(DeclReferenceExprSyntax.self),
           isTypeName(ref.baseName.text)
        {
            // `T.self` — produce a metatype-shaped opaque value carrying
            // the type name. Used by `JSONDecoder.decode(_:from:)` and
            // similar bridges that need to know the target type at
            // runtime. We don't need a dedicated `Value` case for this;
            // `.opaque(typeName: "Metatype", value: T as String)` round-
            // trips fine.
            if memberAccess.declName.baseName.text == "self" {
                return .opaque(typeName: "Metatype", value: ref.baseName.text)
            }
            return try await lookupStaticMember(
                typeName: ref.baseName.text,
                member: memberAccess.declName.baseName.text,
                at: memberAccess.positionAfterSkippingLeadingTrivia.utf8Offset
            )
        }
        // `[T].self` — array metatype. Encoded as `"[T]"` so the
        // decoder can recognize and dispatch element-by-element. Same
        // shape works for `[T?].self` (encoded as `[T?]`).
        if memberAccess.declName.baseName.text == "self",
           let arrExpr = base.as(ArrayExprSyntax.self),
           arrExpr.elements.count == 1,
           let inner = arrExpr.elements.first
        {
            let innerText = inner.expression.description.trimmingCharacters(in: .whitespaces)
            return .opaque(typeName: "Metatype", value: "[\(innerText)]")
        }
        // Nested type access: `Calendar.Component.year` — base is itself a
        // member-access whose dotted form (`Calendar.Component`) is a
        // registered type. We don't model nested types via a `typeRef`
        // value; instead we recognize the syntactic pattern and route
        // straight to `lookupStaticMember`.
        if let outerMember = base.as(MemberAccessExprSyntax.self),
           let outerBase = outerMember.base?.as(DeclReferenceExprSyntax.self),
           isTypeName(outerBase.baseName.text)
        {
            let dotted = "\(outerBase.baseName.text).\(outerMember.declName.baseName.text)"
            if isTypeName(dotted) {
                return try await lookupStaticMember(
                    typeName: dotted,
                    member: memberAccess.declName.baseName.text,
                    at: memberAccess.positionAfterSkippingLeadingTrivia.utf8Offset
                )
            }
        }
        let receiver = try await evaluate(base, in: scope)
        let memberName = memberAccess.declName.baseName.text
        return try await lookupProperty(
            memberName,
            on: receiver,
            at: memberAccess.positionAfterSkippingLeadingTrivia.utf8Offset
        )
    }

    func evaluate(subscriptCall: SubscriptCallExprSyntax, in scope: Scope) async throws -> Value {
        if startsOptionalChain(ExprSyntax(subscriptCall)) {
            return try await evaluateInOptionalChain(ExprSyntax(subscriptCall), in: scope)
        }
        let receiver = try await evaluate(subscriptCall.calledExpression, in: scope)
        let argSyntaxes = Array(subscriptCall.arguments)
        // `dict[k, default: fallback]` — two-arg subscript, second has the
        // `default:` label. Returns the value if present, fallback otherwise
        // (no Optional wrapping, unlike the bare subscript).
        if case .dict(let entries) = receiver,
           argSyntaxes.count == 2,
           argSyntaxes[0].label == nil,
           argSyntaxes[1].label?.text == "default"
        {
            let key = try await evaluate(argSyntaxes[0].expression, in: scope)
            if let entry = entries.first(where: { $0.key == key }) {
                return entry.value
            }
            return try await evaluate(argSyntaxes[1].expression, in: scope)
        }
        let args = try await argSyntaxes.asyncMap { try await evaluate($0.expression, in: scope) }
        return try await doSubscript(receiver: receiver, args: args)
    }

    fileprivate func doSubscript(receiver: Value, args: [Value]) async throws -> Value {
        guard args.count == 1 else {
            throw RuntimeError.invalid("subscript expects 1 argument, got \(args.count)")
        }
        switch (receiver, args[0]) {
        case let (.array(arr), .int(i)):
            guard i >= 0 && i < arr.count else {
                throw RuntimeError.invalid(
                    "array index \(i) out of bounds (count \(arr.count))"
                )
            }
            return arr[i]
        case (.array(let arr), .range(let lo, let hi, let closed)):
            // `arr[lo..<hi]` / `arr[lo...hi]` — returns the slice as
            // `[Element]`. Real Swift returns `ArraySlice` but it round-
            // trips through `Array(_:)` so collapsing is fine for scripts.
            let upper = closed ? hi + 1 : hi
            guard lo >= 0, upper <= arr.count, lo <= upper else {
                throw RuntimeError.invalid(
                    "array slice \(lo)..<\(upper) out of bounds (count \(arr.count))"
                )
            }
            return .array(Array(arr[lo..<upper]))
        case (.string(let s), .range(let lo, let hi, let closed)):
            // `"abcde"[1..<3]` — script-friendly String slicing keyed by
            // grapheme-cluster index. Real Swift requires `String.Index`
            // values; we accept Int because that's what scripts actually
            // write for math/text manipulation.
            let upper = closed ? hi + 1 : hi
            let chars = Array(s)
            guard lo >= 0, upper <= chars.count, lo <= upper else {
                throw RuntimeError.invalid(
                    "string slice \(lo)..<\(upper) out of bounds (count \(chars.count))"
                )
            }
            return .string(String(chars[lo..<upper]))
        case let (.dict(entries), key):
            // Dict subscript returns Optional<V>.
            if let entry = entries.first(where: { $0.key == key }) {
                return .optional(entry.value)
            }
            return .optional(nil)
        default:
            throw RuntimeError.invalid(
                "cannot subscript \(typeName(receiver)) with \(typeName(args[0]))"
            )
        }
    }

    /// Property reads: `arr.count`, `s.isEmpty`, `r.lowerBound`, …
    func lookupProperty(_ name: String, on receiver: Value, at offset: Int) async throws -> Value {
        switch receiver {
        case .array(let xs):
            switch name {
            case "count":   return .int(xs.count)
            case "isEmpty": return .bool(xs.isEmpty)
            case "first":   return .optional(xs.first)
            case "last":    return .optional(xs.last)
            case "indices": return .range(lower: 0, upper: xs.count, closed: false)
            default: break
            }
        case .set(let xs):
            switch name {
            case "count":   return .int(xs.count)
            case "isEmpty": return .bool(xs.isEmpty)
            case "first":   return .optional(xs.first)
            default: break
            }
        case .dict(let entries):
            switch name {
            case "count":   return .int(entries.count)
            case "isEmpty": return .bool(entries.isEmpty)
            case "keys":    return .array(entries.map(\.key))
            case "values":  return .array(entries.map(\.value))
            default: break
            }
        case .string(let s):
            switch name {
            case "count":   return .int(s.count)
            case "isEmpty": return .bool(s.isEmpty)
            case "first":
                if let c = s.first { return .optional(.string(String(c))) }
                return .optional(nil)
            case "last":
                if let c = s.last { return .optional(.string(String(c))) }
                return .optional(nil)
            default: break
            }
        case .range(let lo, let hi, let closed):
            switch name {
            case "lowerBound": return .int(lo)
            case "upperBound": return .int(hi)
            case "isEmpty":    return .bool(closed ? lo > hi : lo >= hi)
            case "count":      return .int(closed ? Swift.max(0, hi - lo + 1) : Swift.max(0, hi - lo))
            default: break
            }
        case .double(let d):
            switch name {
            case "isNaN":      return .bool(d.isNaN)
            case "isFinite":   return .bool(d.isFinite)
            case "isInfinite": return .bool(d.isInfinite)
            case "isZero":     return .bool(d.isZero)
            case "magnitude":  return .double(Swift.abs(d))
            default: break
            }
        case .int(let i):
            // Allow `5.magnitude` etc. — limited but useful.
            switch name {
            case "magnitude": return .int(Swift.abs(i))
            default: break
            }
        case .optional(let inner):
            // Allow forced-unwrap-style access via a `value` accessor for tests.
            // Real `!` and optional chaining aren't supported yet.
            if name == "isNil"   { return .bool(inner == nil) }
            if name == "isSome"  { return .bool(inner != nil) }
        case .tuple(let elements, let labels):
            // `t.0`, `t.1`, … are member accesses where the member name
            // parses as a numeric token. Out-of-range yields a clear error.
            if let idx = Int(name) {
                guard idx >= 0 && idx < elements.count else {
                    throw RuntimeError.invalid(
                        "tuple element \(idx) out of bounds (count \(elements.count))"
                    )
                }
                return elements[idx]
            }
            // Label-based access: `mm.min` on `(min: Int, max: Int)`.
            if let idx = labels.firstIndex(of: name), idx < elements.count {
                return elements[idx]
            }
            // Convenience for 2-tuples that come from dictionary iteration:
            // expose `.key` and `.value` to match Swift's `(key:K, value:V)`
            // labelled-tuple shape.
            if elements.count == 2 {
                if name == "key"   { return elements[0] }
                if name == "value" { return elements[1] }
            }
        case .structValue(let typeName, let fields):
            if let f = fields.first(where: { $0.name == name }) {
                return f.value
            }
            // Computed property fallback: invoke the zero-arg getter.
            if let def = structDefs[typeName],
               let getter = def.computedProperties[name]
            {
                let (result, _) = try await invokeStructMethod(
                    getter, on: receiver, fields: fields, args: []
                )
                return result
            }
        case .classInstance(let inst):
            if let f = inst.fields.first(where: { $0.name == name }) {
                return f.value
            }
            // Computed property: walk the inheritance chain to find a
            // getter, then invoke it with `self` bound to this instance.
            if let def = classDefs[inst.typeName],
               let getter = lookupClassComputed(on: def, name)
            {
                return try await invokeClassMethod(
                    getter, on: inst, def: def, args: []
                )
            }
            // Wrapper-class fallback: if the script class wraps a
            // bridged Foundation/stdlib type, try the bridged surface
            // (computed properties + initializers etc.) using the
            // wrapped value as the receiver.
            if let wrapped = wrappedBridgedValue(inst) {
                return try await lookupProperty(name, on: wrapped, at: offset)
            }
        case .enumValue(let typeName, let caseName, _):
            if name == "rawValue" {
                if let raw = enumDefs[typeName]?.cases.first(where: { $0.name == caseName })?.rawValue {
                    return raw
                }
                throw RuntimeError.invalid("'\(typeName)' has no rawValue")
            }
            // Enum computed property added via extension (stored as a method).
            if let getter = enumDefs[typeName]?.methods[name],
               getter.parameters.isEmpty
            {
                return try await invokeBuiltinExtensionMethod(getter, on: receiver, args: [])
            }
        default: break
        }
        // Extension computed property on a built-in receiver type.
        let recvTypeName = registryTypeName(receiver)
        if let getter = extensionComputedProperty(typeName: recvTypeName, name: name) {
            return try await invokeBuiltinExtensionMethod(getter, on: receiver, args: [])
        }
        throw RuntimeError.invalid(
            "value of type '\(typeName(receiver))' has no member '\(name)'"
        )
    }

    /// Method calls: `s.hasPrefix(p)`, `arr.contains(x)`, …
    func invokeMethod(
        _ name: String,
        on receiver: Value,
        args: [Value],
        at offset: Int
    ) async throws -> Value {
        // Ranges share the collection method surface with arrays. Materialize
        // and re-dispatch so `(0..<5).map { … }` works the same as
        // `[0,1,2,3,4].map { … }`. The list is the methods we forward.
        if case .range = receiver {
            let collectionMethods: Set<String> = [
                "map", "filter", "reduce", "forEach", "compactMap",
                "sorted", "reversed", "enumerated",
                "min", "max", "contains",
            ]
            if collectionMethods.contains(name) {
                let asArray = Value.array(try toArray(receiver))
                return try await invokeMethod(name, on: asArray, args: args, at: offset)
            }
        }
        switch receiver {
        case .array(let xs):
            switch name {
            case "contains":
                try expect(args.count == 1, "Array.contains: 1 argument")
                // .contains(where: closure) dispatches to where-form;
                // .contains(value) compares element-wise.
                if case .function(let fn) = args[0] {
                    for el in xs {
                        let r = try await invoke(fn, args: [el])
                        guard case .bool(let yes) = r else {
                            throw RuntimeError.invalid(
                                "Array.contains(where:): closure must return Bool"
                            )
                        }
                        if yes { return .bool(true) }
                    }
                    return .bool(false)
                }
                return .bool(xs.contains(args[0]))
            case "first":
                // `xs.first(where: { … })` — predicate-shaped overload of
                // the property `first`. Property-form arrives via
                // `lookupProperty`, so this branch only ever sees the
                // closure variant.
                let fn = try expectClosure(args, methodName: "Array.first(where:)", arity: 1)
                for el in xs {
                    let r = try await invoke(fn, args: [el])
                    guard case .bool(let yes) = r else {
                        throw RuntimeError.invalid(
                            "Array.first(where:): closure must return Bool"
                        )
                    }
                    if yes { return .optional(el) }
                }
                return .optional(nil)
            case "last":
                let fn = try expectClosure(args, methodName: "Array.last(where:)", arity: 1)
                for el in xs.reversed() {
                    let r = try await invoke(fn, args: [el])
                    guard case .bool(let yes) = r else {
                        throw RuntimeError.invalid(
                            "Array.last(where:): closure must return Bool"
                        )
                    }
                    if yes { return .optional(el) }
                }
                return .optional(nil)
            case "allSatisfy":
                let fn = try expectClosure(args, methodName: "Array.allSatisfy", arity: 1)
                for el in xs {
                    let r = try await invoke(fn, args: [el])
                    guard case .bool(let yes) = r else {
                        throw RuntimeError.invalid(
                            "Array.allSatisfy: closure must return Bool"
                        )
                    }
                    if !yes { return .bool(false) }
                }
                return .bool(true)
            case "sorted":
                if args.isEmpty {
                    return .array(try await sortByNaturalOrder(xs))
                }
                guard args.count == 1, case .function(let fn) = args[0] else {
                    throw RuntimeError.invalid(
                        "Array.sorted: argument must be a closure"
                    )
                }
                return .array(try await sortByClosure(xs, comparator: fn))
            case "reversed":
                try expect(args.isEmpty, "Array.reversed: no arguments")
                return .array(Array(xs.reversed()))
            case "enumerated":
                try expect(args.isEmpty, "Array.enumerated: no arguments")
                return .array(xs.enumerated().map { .tuple([.int($0.offset), $0.element]) })
            case "min":
                try expect(args.isEmpty, "Array.min: no arguments")
                guard !xs.isEmpty else { return .optional(nil) }
                var best = xs[0]
                for v in xs.dropFirst() {
                    if try await compareLess(v, best) { best = v }
                }
                return .optional(best)
            case "max":
                try expect(args.isEmpty, "Array.max: no arguments")
                guard !xs.isEmpty else { return .optional(nil) }
                var best = xs[0]
                for v in xs.dropFirst() {
                    if try await compareLess(best, v) { best = v }
                }
                return .optional(best)
            case "map":
                let fn = try expectClosure(args, methodName: "Array.map", arity: 1)
                var out: [Value] = []
                out.reserveCapacity(xs.count)
                for el in xs {
                    out.append(try await invoke(fn, args: [el]))
                }
                return .array(out)
            case "filter":
                let fn = try expectClosure(args, methodName: "Array.filter", arity: 1)
                var out: [Value] = []
                for el in xs {
                    let v = try await invoke(fn, args: [el])
                    guard case .bool(let keep) = v else {
                        throw RuntimeError.invalid(
                            "Array.filter: closure must return Bool, got \(typeName(v))"
                        )
                    }
                    if keep { out.append(el) }
                }
                return .array(out)
            case "reduce":
                // Only the `reduce(_:_:)` form (closure returns new acc).
                // `reduce(into:_:)` would need inout-parameter support
                // for the closure's first argument; not modelled.
                guard args.count == 2 else {
                    throw RuntimeError.invalid(
                        "Array.reduce: expected initial value and closure"
                    )
                }
                guard case .function(let fn) = args[1] else {
                    throw RuntimeError.invalid(
                        "Array.reduce: second argument must be a closure"
                    )
                }
                var acc = args[0]
                for el in xs {
                    acc = try await invoke(fn, args: [acc, el])
                }
                return acc
            case "compactMap":
                let fn = try expectClosure(args, methodName: "Array.compactMap", arity: 1)
                var out: [Value] = []
                for el in xs {
                    let v = try await invoke(fn, args: [el])
                    if case .optional(let inner) = v {
                        if let unwrapped = inner { out.append(unwrapped) }
                    } else {
                        out.append(v)
                    }
                }
                return .array(out)
            case "forEach":
                let fn = try expectClosure(args, methodName: "Array.forEach", arity: 1)
                for el in xs {
                    _ = try await invoke(fn, args: [el])
                }
                return .void
            case "joined":
                // arr.joined(separator: "...") — labelled args aren't checked.
                let sep: String
                switch args.count {
                case 0: sep = ""
                case 1:
                    guard case .string(let s) = args[0] else {
                        throw RuntimeError.invalid("Array.joined: separator must be String")
                    }
                    sep = s
                default:
                    throw RuntimeError.invalid("Array.joined: expected 0 or 1 argument")
                }
                return .string(xs.map(\.description).joined(separator: sep))
            case "prefix":
                // `xs.prefix(n)` — first `n` elements (clamped to count).
                guard args.count == 1, case .int(let n) = args[0] else {
                    throw RuntimeError.invalid("Array.prefix: argument must be Int")
                }
                return .array(Array(xs.prefix(Swift.max(0, n))))
            case "suffix":
                guard args.count == 1, case .int(let n) = args[0] else {
                    throw RuntimeError.invalid("Array.suffix: argument must be Int")
                }
                return .array(Array(xs.suffix(Swift.max(0, n))))
            case "dropFirst":
                let n: Int
                if args.isEmpty { n = 1 }
                else if args.count == 1, case .int(let v) = args[0] { n = v }
                else {
                    throw RuntimeError.invalid("Array.dropFirst: 0 or 1 Int argument")
                }
                return .array(Array(xs.dropFirst(Swift.max(0, n))))
            case "dropLast":
                let n: Int
                if args.isEmpty { n = 1 }
                else if args.count == 1, case .int(let v) = args[0] { n = v }
                else {
                    throw RuntimeError.invalid("Array.dropLast: 0 or 1 Int argument")
                }
                return .array(Array(xs.dropLast(Swift.max(0, n))))
            case "flatMap":
                // `xs.flatMap { … }` — closure returns `[T]`, results
                // are concatenated. Distinct from `compactMap` (which
                // unwraps Optional<T>).
                let fn = try expectClosure(args, methodName: "Array.flatMap", arity: 1)
                var out: [Value] = []
                for el in xs {
                    let r = try await invoke(fn, args: [el])
                    if case .array(let inner) = r {
                        out.append(contentsOf: inner)
                    } else {
                        throw RuntimeError.invalid(
                            "Array.flatMap: closure must return Array, got \(typeName(r))"
                        )
                    }
                }
                return .array(out)
            case "firstIndex":
                // Two shapes: `firstIndex(of: x)` and `firstIndex(where:)`.
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Array.firstIndex: 1 argument")
                }
                if case .function(let fn) = args[0] {
                    for (i, el) in xs.enumerated() {
                        let r = try await invoke(fn, args: [el])
                        guard case .bool(let yes) = r else {
                            throw RuntimeError.invalid(
                                "Array.firstIndex(where:): closure must return Bool"
                            )
                        }
                        if yes { return .optional(.int(i)) }
                    }
                    return .optional(nil)
                }
                if let i = xs.firstIndex(of: args[0]) {
                    return .optional(.int(i))
                }
                return .optional(nil)
            case "lastIndex":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Array.lastIndex: 1 argument")
                }
                if case .function(let fn) = args[0] {
                    for (i, el) in xs.enumerated().reversed() {
                        let r = try await invoke(fn, args: [el])
                        guard case .bool(let yes) = r else {
                            throw RuntimeError.invalid(
                                "Array.lastIndex(where:): closure must return Bool"
                            )
                        }
                        if yes { return .optional(.int(i)) }
                    }
                    return .optional(nil)
                }
                if let i = xs.lastIndex(of: args[0]) {
                    return .optional(.int(i))
                }
                return .optional(nil)
            case "starts":
                // `xs.starts(with: [a, b, c])` — prefix match by element.
                guard args.count == 1, case .array(let prefix) = args[0] else {
                    throw RuntimeError.invalid("Array.starts(with:): argument must be Array")
                }
                if prefix.count > xs.count { return .bool(false) }
                for i in 0..<prefix.count where xs[i] != prefix[i] {
                    return .bool(false)
                }
                return .bool(true)
            case "shuffled":
                // Non-mutating: returns a new array.
                try expect(args.isEmpty, "Array.shuffled: no arguments")
                return .array(xs.shuffled())
            case "split":
                // `xs.split(separator: 0)` — break the array on each
                // occurrence of `separator`, drop empty subsequences
                // (matching Swift's default `omittingEmptySubsequences:`).
                // Real Swift returns `[ArraySlice<E>]`; we collapse to
                // `[[E]]`, which round-trips through `Array(_:)` anyway.
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Array.split: 1 argument")
                }
                let sep = args[0]
                var groups: [[Value]] = []
                var cur: [Value] = []
                for el in xs {
                    if el == sep {
                        if !cur.isEmpty { groups.append(cur); cur = [] }
                    } else {
                        cur.append(el)
                    }
                }
                if !cur.isEmpty { groups.append(cur) }
                return .array(groups.map { .array($0) })
            case "elementsEqual":
                guard args.count == 1, case .array(let other) = args[0] else {
                    throw RuntimeError.invalid("Array.elementsEqual: argument must be Array")
                }
                return .bool(xs == other)
            default: break
            }
        case .string(let s):
            switch name {
            case "hasPrefix":
                try expect(args.count == 1, "String.hasPrefix: 1 argument")
                guard case .string(let p) = args[0] else {
                    throw RuntimeError.invalid("String.hasPrefix: argument must be String")
                }
                return .bool(s.hasPrefix(p))
            case "hasSuffix":
                try expect(args.count == 1, "String.hasSuffix: 1 argument")
                guard case .string(let p) = args[0] else {
                    throw RuntimeError.invalid("String.hasSuffix: argument must be String")
                }
                return .bool(s.hasSuffix(p))
            case "contains":
                try expect(args.count == 1, "String.contains: 1 argument")
                // Predicate form: `s.contains { $0 == "a" }` — closure
                // takes a Character. We model Character as a single-char
                // String, so the closure receives a single-char `.string`.
                if case .function(let fn) = args[0] {
                    for c in s {
                        let r = try await invoke(fn, args: [.string(String(c))])
                        guard case .bool(let yes) = r else {
                            throw RuntimeError.invalid(
                                "String.contains(where:): closure must return Bool"
                            )
                        }
                        if yes { return .bool(true) }
                    }
                    return .bool(false)
                }
                guard case .string(let p) = args[0] else {
                    throw RuntimeError.invalid("String.contains: argument must be String")
                }
                return .bool(s.contains(p))
            case "uppercased":
                try expect(args.isEmpty, "String.uppercased: no arguments")
                return .string(s.uppercased())
            case "lowercased":
                try expect(args.isEmpty, "String.lowercased: no arguments")
                return .string(s.lowercased())
            case "split":
                // .split(separator: " ") — single-character separator only
                // for now (matches the most common LLM usage).
                try expect(args.count == 1, "String.split: 1 argument")
                guard case .string(let sep) = args[0] else {
                    throw RuntimeError.invalid("String.split: separator must be String")
                }
                let parts = s.split(separator: sep).map { Value.string(String($0)) }
                return .array(parts)
            case "reversed":
                // Real Swift returns `ReversedCollection<String>`, which
                // round-trips through `String(_:)` to a String. Scripts
                // overwhelmingly want the String form, so collapse it.
                try expect(args.isEmpty, "String.reversed: no arguments")
                return .string(String(s.reversed()))
            case "starts":
                // `s.starts(with: prefix)` — alias for hasPrefix on String.
                guard args.count == 1, case .string(let p) = args[0] else {
                    throw RuntimeError.invalid("String.starts(with:): argument must be String")
                }
                return .bool(s.hasPrefix(p))
            case "prefix":
                // `s.prefix(n)` — first `n` characters. Real Swift
                // returns `Substring`; we collapse to `String` (a
                // `Substring` round-trips through `String(_:)` anyway).
                guard args.count == 1, case .int(let n) = args[0] else {
                    throw RuntimeError.invalid("String.prefix: argument must be Int")
                }
                return .string(String(s.prefix(Swift.max(0, n))))
            case "suffix":
                guard args.count == 1, case .int(let n) = args[0] else {
                    throw RuntimeError.invalid("String.suffix: argument must be Int")
                }
                return .string(String(s.suffix(Swift.max(0, n))))
            case "dropFirst":
                let n: Int
                if args.isEmpty { n = 1 }
                else if args.count == 1, case .int(let v) = args[0] { n = v }
                else {
                    throw RuntimeError.invalid("String.dropFirst: 0 or 1 Int argument")
                }
                return .string(String(s.dropFirst(Swift.max(0, n))))
            case "dropLast":
                let n: Int
                if args.isEmpty { n = 1 }
                else if args.count == 1, case .int(let v) = args[0] { n = v }
                else {
                    throw RuntimeError.invalid("String.dropLast: 0 or 1 Int argument")
                }
                return .string(String(s.dropLast(Swift.max(0, n))))
            // `padding(toLength:withPad:startingAt:)` lives in Foundation
            // (and is generic over `T: StringProtocol`), so it's
            // hand-registered in `FoundationModule`. Falls through here
            // and reaches the registry only after `import Foundation`.
            default: break
            }
        case .range(let lo, let hi, let closed):
            if name == "contains" {
                try expect(args.count == 1, "Range.contains: 1 argument")
                guard case .int(let i) = args[0] else {
                    throw RuntimeError.invalid("Range.contains: argument must be Int")
                }
                return .bool(closed ? (i >= lo && i <= hi) : (i >= lo && i < hi))
            }
            // Sequence-style methods on Range: materialize the range as
            // `[Int]` on demand, then dispatch through the same code as
            // Array. Acceptable for the script-sized ranges scripts use;
            // a lazy implementation can come later if needed.
            switch name {
            case "map", "filter", "reduce", "compactMap", "forEach",
                 "allSatisfy", "min", "max", "sorted", "reversed",
                 "enumerated", "first", "last", "prefix", "suffix",
                 "dropFirst", "dropLast", "flatMap", "starts",
                 "firstIndex", "lastIndex", "elementsEqual", "shuffled",
                 "split":
                let upper = closed ? hi : hi - 1
                let materialized: [Value] = upper >= lo ? (lo...upper).map { .int($0) } : []
                return try await invokeMethod(name, on: .array(materialized), args: args, at: offset)
            default: break
            }
        case .dict(let entries):
            // Dict methods. Closure-style methods receive each entry as a
            // `(key, value)` tuple, mirroring Swift's `for (k, v) in dict`.
            if name == "sorted" {
                let fn = try expectClosure(args, methodName: "Dictionary.sorted", arity: 2)
                let pairs = entries.map { Value.tuple([$0.key, $0.value], labels: ["key", "value"]) }
                return .array(try await sortByClosure(pairs, comparator: fn))
            }
            if name == "contains" {
                try expect(args.count == 1, "Dictionary.contains: 1 argument")
                if case .function(let fn) = args[0] {
                    for entry in entries {
                        let pair: Value = .tuple([entry.key, entry.value])
                        let r = try await invoke(fn, args: [pair])
                        guard case .bool(let yes) = r else {
                            throw RuntimeError.invalid("Dictionary.contains(where:): closure must return Bool")
                        }
                        if yes { return .bool(true) }
                    }
                    return .bool(false)
                }
                return .bool(entries.contains { $0.key == args[0] })
            }
            if name == "mapValues" {
                let fn = try expectClosure(args, methodName: "Dictionary.mapValues", arity: 1)
                var out: [DictEntry] = []
                for e in entries {
                    out.append(DictEntry(key: e.key, value: try await invoke(fn, args: [e.value])))
                }
                return .dict(out)
            }
            if name == "compactMapValues" {
                let fn = try expectClosure(args, methodName: "Dictionary.compactMapValues", arity: 1)
                var out: [DictEntry] = []
                for e in entries {
                    let r = try await invoke(fn, args: [e.value])
                    if case .optional(let inner) = r {
                        if let v = inner { out.append(DictEntry(key: e.key, value: v)) }
                    } else {
                        out.append(DictEntry(key: e.key, value: r))
                    }
                }
                return .dict(out)
            }
            if name == "filter" {
                let fn = try expectClosure(args, methodName: "Dictionary.filter", arity: 1)
                var out: [DictEntry] = []
                for e in entries {
                    let r = try await invoke(fn, args: [.tuple([e.key, e.value])])
                    guard case .bool(let keep) = r else {
                        throw RuntimeError.invalid(
                            "Dictionary.filter: closure must return Bool, got \(typeName(r))"
                        )
                    }
                    if keep { out.append(e) }
                }
                return .dict(out)
            }
            if name == "reduce" {
                guard args.count == 2, case .function(let fn) = args[1] else {
                    throw RuntimeError.invalid(
                        "Dictionary.reduce: expected initial value and closure"
                    )
                }
                var acc = args[0]
                for e in entries {
                    acc = try await invoke(fn, args: [acc, .tuple([e.key, e.value])])
                }
                return acc
            }
            if name == "forEach" {
                let fn = try expectClosure(args, methodName: "Dictionary.forEach", arity: 1)
                for e in entries {
                    _ = try await invoke(fn, args: [.tuple([e.key, e.value])])
                }
                return .void
            }
            if name == "allSatisfy" {
                let fn = try expectClosure(args, methodName: "Dictionary.allSatisfy", arity: 1)
                for e in entries {
                    let r = try await invoke(fn, args: [.tuple([e.key, e.value])])
                    guard case .bool(let yes) = r else {
                        throw RuntimeError.invalid(
                            "Dictionary.allSatisfy: closure must return Bool"
                        )
                    }
                    if !yes { return .bool(false) }
                }
                return .bool(true)
            }
            if name == "first" {
                // `dict.first(where: …)` — returns Optional<(K, V)>.
                let fn = try expectClosure(args, methodName: "Dictionary.first(where:)", arity: 1)
                for e in entries {
                    let pair: Value = .tuple([e.key, e.value])
                    let r = try await invoke(fn, args: [pair])
                    guard case .bool(let yes) = r else {
                        throw RuntimeError.invalid(
                            "Dictionary.first(where:): closure must return Bool"
                        )
                    }
                    if yes { return .optional(pair) }
                }
                return .optional(nil)
            }
            if name == "min" {
                let fn = try expectClosure(args, methodName: "Dictionary.min", arity: 2)
                var pairs = entries.map { Value.tuple([$0.key, $0.value], labels: ["key", "value"]) }
                guard !pairs.isEmpty else { return .optional(nil) }
                let sorted = try await sortByClosure(pairs, comparator: fn)
                return .optional(sorted.first)
            }
            if name == "max" {
                let fn = try expectClosure(args, methodName: "Dictionary.max", arity: 2)
                let pairs = entries.map { Value.tuple([$0.key, $0.value], labels: ["key", "value"]) }
                guard !pairs.isEmpty else { return .optional(nil) }
                let sorted = try await sortByClosure(pairs, comparator: fn)
                return .optional(sorted.last)
            }
            if name == "merging" {
                // `dict.merging(other, uniquingKeysWith: combine)` —
                // returns a new dict with entries from both, calling
                // `combine(old, new)` for duplicate keys.
                guard args.count == 2,
                      case .dict(let other) = args[0],
                      case .function(let fn) = args[1]
                else {
                    throw RuntimeError.invalid(
                        "Dictionary.merging(_:uniquingKeysWith:): expected (Dictionary, closure)"
                    )
                }
                var out = entries
                for o in other {
                    if let i = out.firstIndex(where: { $0.key == o.key }) {
                        out[i].value = try await invoke(fn, args: [out[i].value, o.value])
                    } else {
                        out.append(o)
                    }
                }
                return .dict(out)
            }
        case .set(let xs):
            switch name {
            case "contains":
                try expect(args.count == 1, "Set.contains: 1 argument")
                // Predicate form: `set.contains { … }`.
                if case .function(let fn) = args[0] {
                    for el in xs {
                        let r = try await invoke(fn, args: [el])
                        guard case .bool(let yes) = r else {
                            throw RuntimeError.invalid(
                                "Set.contains(where:): closure must return Bool"
                            )
                        }
                        if yes { return .bool(true) }
                    }
                    return .bool(false)
                }
                return .bool(xs.contains(args[0]))
            case "allSatisfy":
                let fn = try expectClosure(args, methodName: "Set.allSatisfy", arity: 1)
                for el in xs {
                    let r = try await invoke(fn, args: [el])
                    guard case .bool(let yes) = r else {
                        throw RuntimeError.invalid(
                            "Set.allSatisfy: closure must return Bool"
                        )
                    }
                    if !yes { return .bool(false) }
                }
                return .bool(true)
            case "min":
                if args.isEmpty {
                    guard !xs.isEmpty else { return .optional(nil) }
                    var best = xs[0]
                    for v in xs.dropFirst() {
                        if try await compareLess(v, best) { best = v }
                    }
                    return .optional(best)
                }
                let fn = try expectClosure(args, methodName: "Set.min", arity: 2)
                guard !xs.isEmpty else { return .optional(nil) }
                let sorted = try await sortByClosure(xs, comparator: fn)
                return .optional(sorted.first)
            case "max":
                if args.isEmpty {
                    guard !xs.isEmpty else { return .optional(nil) }
                    var best = xs[0]
                    for v in xs.dropFirst() {
                        if try await compareLess(best, v) { best = v }
                    }
                    return .optional(best)
                }
                let fn = try expectClosure(args, methodName: "Set.max", arity: 2)
                guard !xs.isEmpty else { return .optional(nil) }
                let sorted = try await sortByClosure(xs, comparator: fn)
                return .optional(sorted.last)
            case "isSubset":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.isSubset(of:): 1 argument")
                }
                let other = try iterableToArray(args[0])
                return .bool(xs.allSatisfy { other.contains($0) })
            case "isSuperset":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.isSuperset(of:): 1 argument")
                }
                let other = try iterableToArray(args[0])
                return .bool(other.allSatisfy { xs.contains($0) })
            case "isDisjoint":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.isDisjoint(with:): 1 argument")
                }
                let other = try iterableToArray(args[0])
                return .bool(xs.allSatisfy { !other.contains($0) })
            case "union":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.union: 1 argument")
                }
                var out = xs
                for v in try iterableToArray(args[0]) where !out.contains(v) {
                    out.append(v)
                }
                return .set(out)
            case "intersection":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.intersection: 1 argument")
                }
                let other = try iterableToArray(args[0])
                return .set(xs.filter { other.contains($0) })
            case "subtracting":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.subtracting: 1 argument")
                }
                let other = try iterableToArray(args[0])
                return .set(xs.filter { !other.contains($0) })
            case "symmetricDifference":
                guard args.count == 1 else {
                    throw RuntimeError.invalid("Set.symmetricDifference: 1 argument")
                }
                let other = try iterableToArray(args[0])
                let onlyA = xs.filter { !other.contains($0) }
                let onlyB = other.filter { !xs.contains($0) }
                return .set(onlyA + onlyB)
            // Sequence-style closure methods. Returning Array (not Set)
            // matches Swift — `Set.map { … }` is `[T]`, not `Set<T>`.
            case "map":
                let fn = try expectClosure(args, methodName: "Set.map", arity: 1)
                return .array(try await xs.asyncMap { try await invoke(fn, args: [$0]) })
            case "filter":
                // `Set.filter { … }` returns `Set<T>`, not `[T]`.
                let fn = try expectClosure(args, methodName: "Set.filter", arity: 1)
                var out: [Value] = []
                for el in xs {
                    let r = try await invoke(fn, args: [el])
                    guard case .bool(let keep) = r else {
                        throw RuntimeError.invalid("Set.filter: closure must return Bool")
                    }
                    if keep { out.append(el) }
                }
                return .set(out)
            case "reduce":
                guard args.count == 2, case .function(let fn) = args[1] else {
                    throw RuntimeError.invalid("Set.reduce: expected initial value and closure")
                }
                var acc = args[0]
                for el in xs {
                    acc = try await invoke(fn, args: [acc, el])
                }
                return acc
            case "forEach":
                let fn = try expectClosure(args, methodName: "Set.forEach", arity: 1)
                for el in xs { _ = try await invoke(fn, args: [el]) }
                return .void
            case "sorted":
                // Two shapes: `.sorted()` (uses natural ordering) and
                // `.sorted(by: { $0 < $1 })`. Returns `[Element]`.
                if args.isEmpty {
                    return .array(try await sortByNaturalOrder(xs))
                }
                let fn = try expectClosure(args, methodName: "Set.sorted", arity: 2)
                return .array(try await sortByClosure(xs, comparator: fn))
            default: break
            }
        case .double(let d):
            switch name {
            case "squareRoot":
                try expect(args.isEmpty, "Double.squareRoot: no arguments")
                return .double(d.squareRoot())
            case "rounded":
                // `d.rounded()` (default schoolbook), or
                // `d.rounded(.up)` / `.down` / `.toNearestOrEven` / etc.
                // FloatingPointRoundingRule arrives as an opaque carrier
                // since we model the enum via `lookupStaticMember` for
                // `FloatingPointRoundingRule.up` etc.
                if args.isEmpty {
                    return .double(d.rounded())
                }
                guard args.count == 1,
                      case .opaque(typeName: "FloatingPointRoundingRule", let any) = args[0],
                      let rule = any as? FloatingPointRoundingRule
                else {
                    throw RuntimeError.invalid(
                        "Double.rounded: argument must be a FloatingPointRoundingRule"
                    )
                }
                return .double(d.rounded(rule))
            case "magnitude":
                try expect(args.isEmpty, "Double.magnitude: no arguments")
                return .double(Swift.abs(d))
            default: break
            }
        case .structValue(let typeName, _) where typeName == "FileManager":
            return try await invokeFileManagerMethod(name, args: args)
        case .optional(let inner):
            // `Optional.map { … }` — apply closure to the wrapped value
            // (if any) and rewrap the result. `Optional.flatMap { … }`
            // expects the closure itself to return Optional<U>; if it
            // already returns Optional, we don't double-wrap.
            switch name {
            case "map":
                let fn = try expectClosure(args, methodName: "Optional.map", arity: 1)
                if let v = inner {
                    return .optional(try await invoke(fn, args: [v]))
                }
                return .optional(nil)
            case "flatMap":
                let fn = try expectClosure(args, methodName: "Optional.flatMap", arity: 1)
                if let v = inner {
                    let r = try await invoke(fn, args: [v])
                    if case .optional = r { return r }
                    return .optional(r)
                }
                return .optional(nil)
            default: break
            }
        case .structValue(let typeName, let fields):
            if let def = structDefs[typeName], let method = def.methods[name] {
                // This path is only reached when the call site doesn't
                // expose the receiver's variable (e.g. method call on a
                // chained expression). Mutating methods can't be called
                // here because we'd have nowhere to write the result back.
                if method.isMutating {
                    throw RuntimeError.invalid(
                        "cannot use mutating member '\(name)' on a non-variable receiver"
                    )
                }
                let (result, _) = try await invokeStructMethod(
                    method, on: receiver, fields: fields, args: args
                )
                return result
            }
        case .enumValue:
            // Instance method on an enum value: bind `self` to the enum
            // and invoke the method body. (No mutating-method support yet.)
            if case .enumValue(let typeName, _, _) = receiver,
               let def = enumDefs[typeName],
               let method = def.methods[name]
            {
                guard case .user(let body, let capturedScope) = method.kind else {
                    throw RuntimeError.invalid("enum method must be user-defined")
                }
                let callScope = Scope(parent: capturedScope)
                callScope.bind("self", value: receiver, mutable: false)
                guard args.count == method.parameters.count else {
                    throw RuntimeError.invalid(
                        "\(method.name): expected \(method.parameters.count) argument(s), got \(args.count)"
                    )
                }
                for (param, value) in zip(method.parameters, args) {
                    callScope.bind(param.name, value: value, mutable: false)
                }
                returnTypeStack.append(method.returnType)
                defer { returnTypeStack.removeLast() }
                do {
                    var last: Value = .void
                    for item in body {
                        last = try await execute(item: item, in: callScope)
                    }
                    return last
                } catch let signal as ReturnSignal {
                    return signal.value
                }
            }
        default: break
        }
        // User-declared extension on a built-in type (Int, Double, …).
        let recvTypeName = registryTypeName(receiver)
        if let extFn = extensionMethod(typeName: recvTypeName, name: name) {
            return try await invokeBuiltinExtensionMethod(extFn, on: receiver, args: args)
        }
        // Enum extension methods (treated like instance methods).
        if case .enumValue(let enumTypeName, _, _) = receiver,
           let method = enumDefs[enumTypeName]?.methods[name]
        {
            return try await invokeBuiltinExtensionMethod(method, on: receiver, args: args)
        }
        throw RuntimeError.invalid(
            "value of type '\(typeName(receiver))' has no member '\(name)'"
        )
    }
}

private func expect(_ ok: Bool, _ message: @autoclosure () -> String) throws {
    if !ok { throw RuntimeError.invalid("expected: \(message())") }
}

extension Interpreter {
    fileprivate func expectClosure(
        _ args: [Value],
        methodName: String,
        arity expected: Int
    ) throws -> Function {
        guard args.count == 1 else {
            throw RuntimeError.invalid("\(methodName): expected 1 closure argument, got \(args.count)")
        }
        guard case .function(let fn) = args[0] else {
            throw RuntimeError.invalid("\(methodName): expected a closure, got \(typeName(args[0]))")
        }
        return fn
    }

    /// Sort a homogeneous numeric/string array by Swift's natural ordering.
    /// Uses a manual merge sort because Swift's `Array.sort` takes a
    /// synchronous comparator and our `compareLess` (which routes through
    /// user `<` overloads) is async-throwing.
    func sortByNaturalOrder(_ xs: [Value]) async throws -> [Value] {
        return try await asyncMergeSort(xs) { try await self.compareLess($0, $1) }
    }

    func sortByClosure(_ xs: [Value], comparator fn: Function) async throws -> [Value] {
        return try await asyncMergeSort(xs) { a, b in
            let r = try await self.invoke(fn, args: [a, b])
            guard case .bool(let lt) = r else {
                throw RuntimeError.invalid(
                    "Array.sorted: comparator must return Bool, got \(typeName(r))"
                )
            }
            return lt
        }
    }

    private func asyncMergeSort(
        _ xs: [Value],
        by less: (Value, Value) async throws -> Bool
    ) async throws -> [Value] {
        if xs.count <= 1 { return xs }
        let mid = xs.count / 2
        let left = try await asyncMergeSort(Array(xs[..<mid]), by: less)
        let right = try await asyncMergeSort(Array(xs[mid...]), by: less)
        var merged: [Value] = []
        merged.reserveCapacity(xs.count)
        var i = 0, j = 0
        while i < left.count && j < right.count {
            if try await less(left[i], right[j]) {
                merged.append(left[i]); i += 1
            } else {
                merged.append(right[j]); j += 1
            }
        }
        merged.append(contentsOf: left[i...])
        merged.append(contentsOf: right[j...])
        return merged
    }

    /// Strict natural-order comparison. Int/Double/String use built-in `<`;
    /// user struct types delegate to a `static func <(a: T, b: T) -> Bool`
    /// if declared (Comparable conformance).
    fileprivate func compareLess(_ a: Value, _ b: Value) async throws -> Bool {
        switch (a, b) {
        case let (.int(x), .int(y)):       return x < y
        case let (.double(x), .double(y)): return x < y
        case let (.string(x), .string(y)): return x < y
        case let (.structValue(an, _), .structValue(bn, _)) where an == bn:
            if let opFn = structDefs[an]?.staticMembers["<"],
               case .function(let fn) = opFn
            {
                let r = try await invoke(fn, args: [a, b])
                guard case .bool(let lt) = r else {
                    throw RuntimeError.invalid("'<' for \(an) must return Bool")
                }
                return lt
            }
            throw RuntimeError.invalid("cannot compare \(an) with \(an)")
        default:
            throw RuntimeError.invalid(
                "cannot compare \(typeName(a)) with \(typeName(b))"
            )
        }
    }
}
