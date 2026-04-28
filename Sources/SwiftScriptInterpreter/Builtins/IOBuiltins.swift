extension Interpreter {
    func registerIOBuiltins() {
        registerBuiltin(name: "print") { [weak self] args in
            // Route each item through `describe` so script-defined
            // `description` getters (CustomStringConvertible-style) are
            // honored — the labeled form lives in `tryPrintCall`, this
            // is the no-keyword-args fallback used for plain
            // `print(x)` / `print(x, y)`.
            guard let self else { return .void }
            let parts = try await args.asyncMap { try await self.describe($0) }
            self.output(parts.joined(separator: " "))
            return .void
        }

        // `dump(_:)` — print the value's debugDescription.
        // Real Swift's dump produces an indented tree of every reflected
        // child. We don't model `Mirror`, so a single-line debug
        // description (honoring `CustomDebugStringConvertible`) is the
        // pragmatic stand-in.
        registerBuiltin(name: "dump") { [weak self] args in
            guard let self else { return .void }
            guard let v = args.first else { return .void }
            let s = try await self.debugDescribe(v)
            self.output("- " + s)
            // Real `dump` returns the value it was given, so chained
            // `let x = dump(expr)` works.
            return v
        }

        // `String(reflecting:)` — produces what `dump` prints. Honors
        // `CustomDebugStringConvertible.debugDescription` on script
        // types; falls back to the regular description for everything
        // else.
        registerInit(on: "String", labels: ["reflecting"]) { [weak self] args in
            guard let self else { return .string("") }
            guard let v = args.first else { return .string("") }
            return .string(try await self.debugDescribe(v))
        }

        // FloatingPointRoundingRule cases as opaque values, registered
        // statically so script code can write
        // `d.rounded(FloatingPointRoundingRule.up)` (or `.up` shorthand
        // when the rounded() method site supplies the context type).
        let rules: [(String, FloatingPointRoundingRule)] = [
            ("toNearestOrEven",  .toNearestOrEven),
            ("toNearestOrAwayFromZero", .toNearestOrAwayFromZero),
            ("up",               .up),
            ("down",             .down),
            ("towardZero",       .towardZero),
            ("awayFromZero",     .awayFromZero),
        ]
        for (name, rule) in rules {
            registerStaticValue(
                on: "FloatingPointRoundingRule",
                name: name,
                value: .opaque(typeName: "FloatingPointRoundingRule", value: rule)
            )
        }

        // Diagnostic builtins. `assert` is a no-op when condition is true
        // and throws a runtime error with the supplied message otherwise.
        // We don't model release/debug build conditioning — the assertion
        // always runs.
        registerBuiltin(name: "assert") { args in
            guard let first = args.first, case .bool(let cond) = first else {
                throw RuntimeError.invalid("assert: first argument must be Bool")
            }
            if !cond {
                let msg: String
                if args.count >= 2, case .string(let s) = args[1] { msg = s }
                else { msg = "assertion failed" }
                throw RuntimeError.invalid("assertion failed: \(msg)")
            }
            return .void
        }
        registerBuiltin(name: "precondition") { args in
            guard let first = args.first, case .bool(let cond) = first else {
                throw RuntimeError.invalid("precondition: first argument must be Bool")
            }
            if !cond {
                let msg: String
                if args.count >= 2, case .string(let s) = args[1] { msg = s }
                else { msg = "precondition failed" }
                throw RuntimeError.invalid("precondition failed: \(msg)")
            }
            return .void
        }
        registerBuiltin(name: "fatalError") { args in
            let msg: String
            if let first = args.first, case .string(let s) = first { msg = s }
            else { msg = "fatal error" }
            throw RuntimeError.invalid("fatal error: \(msg)")
        }
        // `readLine()` reads a line from stdin, returns String? (nil on
        // EOF). `readLine(strippingNewline:)` mirrors the stdlib overload.
        registerBuiltin(name: "readLine") { args in
            // Either no args, or a single bool with `strippingNewline`
            // semantics. Default is true (matches stdlib).
            var stripping = true
            if args.count == 1 {
                guard case .bool(let v) = args[0] else {
                    throw RuntimeError.invalid("readLine: argument must be Bool")
                }
                stripping = v
            }
            if let line = Swift.readLine(strippingNewline: stripping) {
                return .optional(.string(line))
            }
            return .optional(nil)
        }

        registerBuiltin(name: "String") { [weak self] args in
            // `String(x)` (describing-style) is stdlib and always works.
            // `String(format: f, …)` is Foundation — gate on the import.
            switch args.count {
            case 1:
                return .string(args[0].description)
            case 2...:
                guard self?.isImported(any: "Foundation", "Darwin", "Glibc") == true else {
                    // Mirror swiftc's wording when the format-init isn't
                    // available because Foundation hasn't been imported.
                    throw RuntimeError.invalid("no exact matches in call to initializer")
                }
                guard case .string(let fmt) = args[0] else {
                    throw RuntimeError.invalid(
                        "String(format:): first argument must be a String"
                    )
                }
                let cvars: [CVarArg] = args.dropFirst().map { v -> CVarArg in
                    switch v {
                    case .int(let i):    return i
                    case .double(let d): return d
                    case .string(let s): return s
                    case .bool(let b):   return b ? "true" : "false"
                    default:             return v.description
                    }
                }
                return .string(String(format: fmt, arguments: cvars))
            default:
                throw RuntimeError.invalid("String: expected at least 1 argument")
            }
        }

        // `String(_:radix:)` and `String(_:radix:uppercase:)` —
        // formatting an Int into a non-decimal base. Common idiom for
        // hex / binary printing.
        registerInit(on: "String", labels: ["_", "radix"]) { args in
            guard args.count == 2,
                  case .int(let v) = args[0],
                  case .int(let radix) = args[1]
            else {
                throw RuntimeError.invalid("String(_:radix:): expected (Int, Int)")
            }
            return .string(String(v, radix: radix))
        }
        registerInit(on: "String", labels: ["_", "radix", "uppercase"]) { args in
            guard args.count == 3,
                  case .int(let v) = args[0],
                  case .int(let radix) = args[1],
                  case .bool(let upper) = args[2]
            else {
                throw RuntimeError.invalid("String(_:radix:uppercase:): expected (Int, Int, Bool)")
            }
            return .string(String(v, radix: radix, uppercase: upper))
        }
        // `Int(_ string: String, radix: Int)` — parse with a non-default
        // base. Returns Int? (nil for malformed input).
        registerInit(on: "Int", labels: ["_", "radix"]) { args in
            guard args.count == 2,
                  case .string(let s) = args[0],
                  case .int(let radix) = args[1]
            else {
                throw RuntimeError.invalid("Int(_:radix:): expected (String, Int)")
            }
            if let i = Int(s, radix: radix) { return .optional(.int(i)) }
            return .optional(nil)
        }

        // `Int(exactly: Double)` — fails (returns nil) if the value
        // isn't representable losslessly. Distinct from `Int(d)` which
        // truncates toward zero.
        registerInit(on: "Int", labels: ["exactly"]) { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Int(exactly:): expected 1 argument")
            }
            switch args[0] {
            case .double(let d):
                if let i = Int(exactly: d) { return .optional(.int(i)) }
                return .optional(nil)
            case .int(let i):
                return .optional(.int(i))
            default:
                throw RuntimeError.invalid("Int(exactly:): expected Double or Int")
            }
        }
        registerInit(on: "Double", labels: ["exactly"]) { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Double(exactly:): expected 1 argument")
            }
            switch args[0] {
            case .int(let i):
                if let d = Double(exactly: i) { return .optional(.double(d)) }
                return .optional(nil)
            case .double(let d):
                return .optional(.double(d))
            default:
                throw RuntimeError.invalid("Double(exactly:): expected Int or Double")
            }
        }

        // `Int(_:)` mirrors Swift: numeric input returns Int, but Int(String)
        // returns Int? (so `Int("42")! == 42` and `Int("hi") ?? 0 == 0`).
        registerBuiltin(name: "Int") { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Int: expected 1 argument, got \(args.count)")
            }
            switch args[0] {
            case .int(let i):    return .int(i)
            case .double(let d): return .int(Int(d))
            case .bool(let b):   return .int(b ? 1 : 0)
            case .string(let s):
                if let i = Int(s) { return .optional(.int(i)) }
                return .optional(nil)
            default:
                throw RuntimeError.invalid("Int: cannot convert \(typeName(args[0]))")
            }
        }

        // Same for `Double(_:)` — String → Double? to match Swift.
        registerBuiltin(name: "Double") { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Double: expected 1 argument, got \(args.count)")
            }
            switch args[0] {
            case .int(let i):    return .double(Double(i))
            case .double(let d): return .double(d)
            case .string(let s):
                if let d = Double(s) { return .optional(.double(d)) }
                return .optional(nil)
            default:
                throw RuntimeError.invalid("Double: cannot convert \(typeName(args[0]))")
            }
        }

        // `Bool(_:)` mirrors Swift's `Bool.init?(_ description: String)`:
        // accepts "true"/"false" only, returns Bool? for the String form.
        registerBuiltin(name: "Bool") { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Bool: expected 1 argument, got \(args.count)")
            }
            switch args[0] {
            case .bool(let b): return .bool(b)
            case .string(let s):
                switch s {
                case "true":  return .optional(.bool(true))
                case "false": return .optional(.bool(false))
                default:      return .optional(nil)
                }
            default:
                throw RuntimeError.invalid("Bool: cannot convert \(typeName(args[0]))")
            }
        }

        // `Array(_:)` builds a flat array from any iterable value (range,
        // string, or another array).
        // `Array(repeating: x, count: n)` — keyword-init form. The
        // `[T](repeating:count:)` sugar already routes through
        // `evaluateTypedArrayInitializer`; this covers the bare-name form.
        registerInit(on: "Array", labels: ["repeating", "count"]) { args in
            guard args.count == 2, case .int(let n) = args[1], n >= 0 else {
                throw RuntimeError.invalid(
                    "Array(repeating:count:): expected (Element, Int)"
                )
            }
            return .array(Array(repeating: args[0], count: n))
        }
        registerBuiltin(name: "Array") { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Array: expected 1 argument")
            }
            switch args[0] {
            case .range(let lo, let hi, let closed):
                let end = closed ? hi + 1 : hi
                return .array((lo..<end).map { .int($0) })
            case .array(let xs):  return .array(xs)
            case .set(let xs):    return .array(xs)
            case .string(let s):  return .array(s.map { .string(String($0)) })
            case .dict(let entries):
                // Real Swift would refuse — `Array(dict)` requires the
                // dict to be exposed via a sequence (`.dict(...)` is one
                // — yields `(key, value)` tuples). We collapse that here.
                return .array(entries.map {
                    Value.tuple([$0.key, $0.value], labels: ["key", "value"])
                })
            default:
                throw RuntimeError.invalid("Array: cannot convert \(typeName(args[0]))")
            }
        }
        // `String(repeating: "ab", count: 3)` — common formatting idiom.
        // Hand-rolled because `registerInit` keys on labels, but the
        // single-arg `String(_:)` already lives in `registerBuiltin`
        // above (line 9) — they'd collide. Wire as a registerInit
        // labelled overload that takes precedence.
        registerInit(on: "String", labels: ["repeating", "count"]) { args in
            guard args.count == 2,
                  case .string(let s) = args[0],
                  case .int(let n) = args[1]
            else {
                throw RuntimeError.invalid(
                    "String(repeating:count:): expected (String, Int)"
                )
            }
            return .string(String(repeating: s, count: Swift.max(0, n)))
        }

        // `zip(a, b)` pairs two sequences into `[(A, B)]`. Truncates to the
        // shorter side, matching Swift.
        registerBuiltin(name: "zip") { [weak self] args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("zip: expected 2 arguments")
            }
            guard let self else { return .array([]) }
            let a = try self.toArray(args[0])
            let b = try self.toArray(args[1])
            let n = Swift.min(a.count, b.count)
            return .array((0..<n).map { .tuple([a[$0], b[$0]]) })
        }

        // `stride(from:to:by:)` — half-open, both Int and Double variants.
        registerBuiltin(name: "stride") { args in
            guard args.count == 3 else {
                throw RuntimeError.invalid("stride: expected 3 arguments (from:to:by:)")
            }
            switch (args[0], args[1], args[2]) {
            case let (.int(from), .int(to), .int(by)):
                guard by != 0 else { throw RuntimeError.invalid("stride: 'by' cannot be 0") }
                var out: [Value] = []
                var i = from
                if by > 0 {
                    while i < to { out.append(.int(i)); i += by }
                } else {
                    while i > to { out.append(.int(i)); i += by }
                }
                return .array(out)
            case let (.double(from), .double(to), .double(by)):
                guard by != 0 else { throw RuntimeError.invalid("stride: 'by' cannot be 0") }
                var out: [Value] = []
                var i = from
                if by > 0 {
                    while i < to { out.append(.double(i)); i += by }
                } else {
                    while i > to { out.append(.double(i)); i += by }
                }
                return .array(out)
            default:
                throw RuntimeError.invalid(
                    "stride: from/to/by must be all Int or all Double"
                )
            }
        }
    }

    /// Convert any iterable value to a flat `[Value]`. Used by `zip`.
    func toArray(_ v: Value) throws -> [Value] {
        switch v {
        case .array(let xs): return xs
        case .range(let lo, let hi, let closed):
            let end = closed ? hi + 1 : hi
            return (lo..<end).map { .int($0) }
        case .string(let s): return s.map { .string(String($0)) }
        default:
            throw RuntimeError.invalid("not iterable: \(typeName(v))")
        }
    }
}
