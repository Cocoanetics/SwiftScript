import Foundation
import SwiftSyntax

/// JSON encode/decode for SwiftScript values, routed through Foundation's
/// `JSONEncoder` / `JSONDecoder` via the `ScriptCodable` bridge. We don't
/// reimplement JSON parsing or formatting — Foundation does that work,
/// and we get its strategies (Date / Data / output flags) for free.
///
/// ## What's covered
///   - Primitives: Int, Double, String, Bool, Optional<T>, [T], [K: V]
///   - User structs: encoded in declaration order, nil optionals omitted.
///   - User enums: payload-less encode as the case name; raw-value
///     enums decode by matching the rawValue.
///   - Foundation Codable types: Date, URL, UUID, Data, Decimal — they
///     ride through their own conformances on the encoder side, and
///     decode via their stdlib `Decodable` impls.
///
/// ## Not covered
///   - Custom `init(from:)` / `encode(to:)` written in script.
///   - `CodingKeys` remapping (we use field names directly).
///   - Decoding enums with associated values (Swift's standard nested
///     keyed-container layout — straightforward to add when needed).
struct JSONModule: BuiltinModule {
    let name = "JSON"

    func register(into i: Interpreter) {
        // The no-arg inits (`JSONEncoder()`, `JSONDecoder()`,
        // `PropertyListEncoder()`, `PropertyListDecoder()`) auto-
        // generate from the symbol graph now that the bridge generator
        // promotes these classes — see
        // `FoundationBridges+JSONEncoder.swift` etc. They used to be
        // hand-rolled here.

        // `encode<T: Encodable>(_:)` and `decode<T: Decodable>(_:from:)`
        // are auto-generated from the Foundation symbol graph in
        // `FoundationBridges+JSONEncoder.swift` /
        // `FoundationBridges+PropertyListEncoder.swift` (encode side)
        // and the manifest's runtime block (decode side, since it
        // captures the interpreter for `userInfo` threading). The
        // hand-rolled versions used to live here.

        // OptionSet cases (`JSONEncoder.OutputFormatting.prettyPrinted`,
        // …) auto-generate now that the bridge generator handles
        // 3-level paths. The DateEncodingStrategy / DateDecodingStrategy
        // values are enum cases (not static lets) so they still need
        // to be hand-rolled here — the symbol-graph case-extraction
        // path is a separate gap.
        i.bridges["static let JSONEncoder.DateEncodingStrategy.iso8601"] =
            .staticValue(.opaque(typeName: "JSONEncoder.DateEncodingStrategy", value: JSONEncoder.DateEncodingStrategy.iso8601))
        i.bridges["static let JSONEncoder.DateEncodingStrategy.secondsSince1970"] =
            .staticValue(.opaque(typeName: "JSONEncoder.DateEncodingStrategy", value: JSONEncoder.DateEncodingStrategy.secondsSince1970))
        i.bridges["static let JSONDecoder.DateDecodingStrategy.iso8601"] =
            .staticValue(.opaque(typeName: "JSONDecoder.DateDecodingStrategy", value: JSONDecoder.DateDecodingStrategy.iso8601))
        i.bridges["static let JSONDecoder.DateDecodingStrategy.secondsSince1970"] =
            .staticValue(.opaque(typeName: "JSONDecoder.DateDecodingStrategy", value: JSONDecoder.DateDecodingStrategy.secondsSince1970))

        // `String.data(using:)` — returns Data?. Hand-rolled because the
        // symbol-graph signature has a defaulted `allowLossyConversion`
        // parameter, which our generator currently treats as required.
        i.bridges["func String.data()"] = .method { recv, args in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.data(using:): receiver must be String")
            }
            guard args.count == 1 else {
                throw RuntimeError.invalid("String.data(using:): expected 1 argument")
            }
            guard case .opaque(typeName: "String.Encoding", let any) = args[0],
                  let enc = any as? String.Encoding
            else {
                throw RuntimeError.invalid("String.data(using:): argument must be String.Encoding")
            }
            if let data = s.data(using: enc) {
                return .optional(.opaque(typeName: "Data", value: data))
            }
            return .optional(nil)
        }
        // `Data(_ bytes: String.UTF8View)` — common idiom for getting a
        // Data from a string literal (`Data(json.utf8)`). We don't model
        // UTF8View; collapse the call shape so `Data(s.utf8)` works by
        // recognizing the receiver as the string itself with `.utf8`
        // applied. The simplest path is a `Data(stringLiteral:)`-like
        // bridge that takes a String directly.
        i.bridges["init Data(_:)"] = .`init` { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Data(_:): expected 1 argument")
            }
            // Accept String.UTF8View (which we model as `.string` after
            // a `.utf8` access — see below).
            switch args[0] {
            case .string(let s):
                return .opaque(typeName: "Data", value: Data(s.utf8))
            case .array(let xs):
                // `Data([UInt8])` — array of Int values that fit in UInt8.
                var bytes: [UInt8] = []
                for v in xs {
                    guard case .int(let i) = v, (0...255).contains(i) else {
                        throw RuntimeError.invalid("Data(_:): array element out of UInt8 range")
                    }
                    bytes.append(UInt8(i))
                }
                return .opaque(typeName: "Data", value: Data(bytes))
            default:
                throw RuntimeError.invalid(
                    "Data(_:): expected String.UTF8View or [UInt8], got \(typeName(args[0]))"
                )
            }
        }
        // `String.utf8` / `.utf16` / `.unicodeScalars` are stdlib
        // surface, not Foundation — they register unconditionally in
        // `registerStringCodeUnitViews()` (Builtins/Registry.swift).
        // `Data(_:)` above accepts the byte array that `.utf8` now
        // produces, so `Data(s.utf8)` keeps working.

        // `String(data:encoding:)` — failable init, returns String?.
        i.bridges["init String(data:encoding:)"] = .`init` { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("String(data:encoding:): expected 2 arguments")
            }
            guard case .opaque(typeName: "Data", let dataAny) = args[0],
                  let data = dataAny as? Data
            else {
                throw RuntimeError.invalid("String(data:encoding:): first argument must be Data")
            }
            guard case .opaque(typeName: "String.Encoding", let encAny) = args[1],
                  let enc = encAny as? String.Encoding
            else {
                throw RuntimeError.invalid("String(data:encoding:): second argument must be String.Encoding")
            }
            if let s = String(data: data, encoding: enc) {
                return .optional(.string(s))
            }
            return .optional(nil)
        }

        // `String.Encoding.utf8` etc. — explicit form. Implicit `.utf8`
        // shorthand at the call site needs contextual typing, deferred.
        let encodings: [(String, String.Encoding)] = [
            ("utf8",         .utf8),
            ("ascii",        .ascii),
            ("utf16",        .utf16),
            ("utf16BigEndian",    .utf16BigEndian),
            ("utf16LittleEndian", .utf16LittleEndian),
            ("utf32",        .utf32),
            ("isoLatin1",    .isoLatin1),
            ("macOSRoman",   .macOSRoman),
        ]
        for (name, enc) in encodings {
            i.bridges["static let String.Encoding.\(name)"] =
                .staticValue(.opaque(typeName: "String.Encoding", value: enc))
        }

        registerJSONSerialization(into: i)
        registerCoderStrategies(into: i)
    }

    // MARK: - JSONSerialization (untyped JSON)

    /// `JSONSerialization.jsonObject(with:)` / `.data(withJSONObject:)`
    /// — the untyped-JSON door (issue #7: previously "no bridge file
    /// at all"). The Any-shaped tree maps onto interpreter values:
    /// objects → `.dict`, arrays → `.array`, strings/numbers/bools →
    /// their primitives, `null` → `.optional(nil)`.
    private func registerJSONSerialization(into i: Interpreter) {
        i.bridges["static func JSONSerialization.jsonObject()"] = .staticMethod { args in
            guard (1...2).contains(args.count) else {
                throw RuntimeError.invalid("JSONSerialization.jsonObject(with:): expected 1-2 arguments, got \(args.count)")
            }
            let data: Data = try unboxOpaque(args[0], as: Data.self, typeName: "Data")
            // Honour the caller's reading options (default []), so a
            // bare-scalar top level only parses when the script passed
            // `.fragmentsAllowed` — matching stock, which throws
            // otherwise.
            let options: JSONSerialization.ReadingOptions = args.count == 2
                ? Self.readingOptions(from: args[1]) : []
            let any: Any
            do {
                any = try JSONSerialization.jsonObject(with: data, options: options)
            } catch {
                throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
            }
            return try Self.value(fromJSONAny: any)
        }
        i.bridges["static func JSONSerialization.data()"] = .staticMethod { args in
            guard (1...2).contains(args.count) else {
                throw RuntimeError.invalid("JSONSerialization.data(withJSONObject:): expected 1-2 arguments, got \(args.count)")
            }
            let options: JSONSerialization.WritingOptions = args.count == 2
                ? Self.writingOptions(from: args[1]) : []
            let object = try Self.jsonAny(from: args[0])
            do {
                let data = try JSONSerialization.data(withJSONObject: object, options: options)
                return boxOpaque(data, typeName: "Data")
            } catch {
                throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
            }
        }
        i.bridges["static func JSONSerialization.isValidJSONObject()"] = .staticMethod { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("JSONSerialization.isValidJSONObject(_:): expected 1 argument, got \(args.count)")
            }
            guard let object = try? Self.jsonAny(from: args[0]) else { return .bool(false) }
            return .bool(JSONSerialization.isValidJSONObject(object))
        }
    }

    /// Collapse an options argument — a single `.opaque` OptionSet
    /// or an array literal of them (`[.sortedKeys, .prettyPrinted]`,
    /// which the static-method dispatch can't coerce to the set type
    /// on its own) — into the concrete OptionSet.
    private static func writingOptions(from value: Value) -> JSONSerialization.WritingOptions {
        var result: JSONSerialization.WritingOptions = []
        for element in optionElements(value) {
            if case .opaque(_, let any) = element,
               let opt = any as? JSONSerialization.WritingOptions
            {
                result.formUnion(opt)
            }
        }
        return result
    }

    private static func readingOptions(from value: Value) -> JSONSerialization.ReadingOptions {
        var result: JSONSerialization.ReadingOptions = []
        for element in optionElements(value) {
            if case .opaque(_, let any) = element,
               let opt = any as? JSONSerialization.ReadingOptions
            {
                result.formUnion(opt)
            }
        }
        return result
    }

    /// Flatten an OptionSet argument to its member values: an array
    /// literal yields its elements, a bare opaque yields itself.
    private static func optionElements(_ value: Value) -> [Value] {
        switch value {
        case .array(let xs): return xs
        case .optional(let inner?): return optionElements(inner)
        default: return [value]
        }
    }

    /// Foundation's untyped JSON tree → interpreter `Value`.
    private static func value(fromJSONAny any: Any) throws -> Value {
        switch any {
        case let dict as [String: Any]:
            return .dict(try dict.map {
                DictEntry(key: .string($0.key), value: try value(fromJSONAny: $0.value))
            })
        case let array as [Any]:
            return .array(try array.map { try value(fromJSONAny: $0) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // NSNumber collapses bools and numerics; the stored ObjC
            // type code is the reliable discriminator. JSON booleans
            // are the boolean singletons ("c"/"B"); floating literals
            // are "f"/"d"; everything else is an integer.
            let code = String(cString: number.objCType)
            if code == "c" || code == "B" {
                return .bool(number.boolValue)
            }
            if code == "f" || code == "d" {
                return .double(number.doubleValue)
            }
            // Unsigned integers past Int64.max ("Q") two's-complement-
            // wrap through int64Value, so route them explicitly: fit
            // into Int when possible, else fall to Double (lossy but
            // non-wrapping — `as? Int` then correctly fails rather
            // than yielding a negative value).
            if code == "Q" {
                let u = number.uint64Value
                return u <= UInt64(Int.max) ? .int(Int(u)) : .double(number.doubleValue)
            }
            if let int = Int(exactly: number.int64Value) {
                return .int(int)
            }
            return .double(number.doubleValue)
        case is NSNull:
            return .optional(nil)
        default:
            throw RuntimeError.invalid(
                "JSONSerialization: unsupported JSON value of type \(type(of: any))")
        }
    }

    /// Interpreter `Value` → the Any tree JSONSerialization writes.
    private static func jsonAny(from value: Value) throws -> Any {
        switch value {
        case .dict(let entries):
            var out: [String: Any] = [:]
            for entry in entries {
                guard case .string(let key) = entry.key else {
                    throw RuntimeError.invalid(
                        "JSONSerialization.data: dictionary keys must be String, got \(typeName(entry.key))")
                }
                out[key] = try jsonAny(from: entry.value)
            }
            return out
        case .array(let xs):
            return try xs.map { try jsonAny(from: $0) }
        case .string(let s): return s
        case .int(let n): return n
        case .double(let d): return d
        case .bool(let b): return b
        case .optional(nil): return NSNull()
        case .optional(let inner?): return try jsonAny(from: inner)
        default:
            throw RuntimeError.invalid(
                "JSONSerialization.data: unsupported value of type \(typeName(value))")
        }
    }

    // MARK: - Encoder / decoder strategies

    /// `JSONEncoder.dateEncodingStrategy = .iso8601` and friends —
    /// the strategy enums aren't Equatable structs, so auto-promotion
    /// skips them; the common cases are hand-registered (issue #7:
    /// "has no settable member 'dateEncodingStrategy'").
    private func registerCoderStrategies(into i: Interpreter) {
        let dateEncoding: [(String, JSONEncoder.DateEncodingStrategy)] = [
            ("deferredToDate", .deferredToDate),
            ("iso8601", .iso8601),
            ("secondsSince1970", .secondsSince1970),
            ("millisecondsSince1970", .millisecondsSince1970),
        ]
        for (name, strategy) in dateEncoding {
            i.bridges["static let JSONEncoder.DateEncodingStrategy.\(name)"] =
                .staticValue(.opaque(typeName: "JSONEncoder.DateEncodingStrategy", value: strategy))
        }
        let dateDecoding: [(String, JSONDecoder.DateDecodingStrategy)] = [
            ("deferredToDate", .deferredToDate),
            ("iso8601", .iso8601),
            ("secondsSince1970", .secondsSince1970),
            ("millisecondsSince1970", .millisecondsSince1970),
        ]
        for (name, strategy) in dateDecoding {
            i.bridges["static let JSONDecoder.DateDecodingStrategy.\(name)"] =
                .staticValue(.opaque(typeName: "JSONDecoder.DateDecodingStrategy", value: strategy))
        }
        i.bridges["static let JSONEncoder.KeyEncodingStrategy.useDefaultKeys"] =
            .staticValue(.opaque(typeName: "JSONEncoder.KeyEncodingStrategy",
                                 value: JSONEncoder.KeyEncodingStrategy.useDefaultKeys))
        i.bridges["static let JSONEncoder.KeyEncodingStrategy.convertToSnakeCase"] =
            .staticValue(.opaque(typeName: "JSONEncoder.KeyEncodingStrategy",
                                 value: JSONEncoder.KeyEncodingStrategy.convertToSnakeCase))
        i.bridges["static let JSONDecoder.KeyDecodingStrategy.useDefaultKeys"] =
            .staticValue(.opaque(typeName: "JSONDecoder.KeyDecodingStrategy",
                                 value: JSONDecoder.KeyDecodingStrategy.useDefaultKeys))
        i.bridges["static let JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase"] =
            .staticValue(.opaque(typeName: "JSONDecoder.KeyDecodingStrategy",
                                 value: JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase))

        i.bridges["var JSONEncoder.dateEncodingStrategy: JSONEncoder.DateEncodingStrategy"] = .computed { recv in
            let encoder: JSONEncoder = try unboxOpaque(recv, as: JSONEncoder.self, typeName: "JSONEncoder")
            return .opaque(typeName: "JSONEncoder.DateEncodingStrategy", value: encoder.dateEncodingStrategy)
        }
        i.bridges["set var JSONEncoder.dateEncodingStrategy: JSONEncoder.DateEncodingStrategy"] = .setter { recv, newValue in
            let encoder: JSONEncoder = try unboxOpaque(recv, as: JSONEncoder.self, typeName: "JSONEncoder")
            guard case .opaque(_, let any) = newValue,
                  let strategy = any as? JSONEncoder.DateEncodingStrategy
            else {
                throw RuntimeError.invalid("JSONEncoder.dateEncodingStrategy: expected a DateEncodingStrategy")
            }
            encoder.dateEncodingStrategy = strategy
        }
        i.bridges["var JSONEncoder.keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy"] = .computed { recv in
            let encoder: JSONEncoder = try unboxOpaque(recv, as: JSONEncoder.self, typeName: "JSONEncoder")
            return .opaque(typeName: "JSONEncoder.KeyEncodingStrategy", value: encoder.keyEncodingStrategy)
        }
        i.bridges["set var JSONEncoder.keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy"] = .setter { recv, newValue in
            let encoder: JSONEncoder = try unboxOpaque(recv, as: JSONEncoder.self, typeName: "JSONEncoder")
            guard case .opaque(_, let any) = newValue,
                  let strategy = any as? JSONEncoder.KeyEncodingStrategy
            else {
                throw RuntimeError.invalid("JSONEncoder.keyEncodingStrategy: expected a KeyEncodingStrategy")
            }
            encoder.keyEncodingStrategy = strategy
        }
        i.bridges["var JSONDecoder.dateDecodingStrategy: JSONDecoder.DateDecodingStrategy"] = .computed { recv in
            let decoder: JSONDecoder = try unboxOpaque(recv, as: JSONDecoder.self, typeName: "JSONDecoder")
            return .opaque(typeName: "JSONDecoder.DateDecodingStrategy", value: decoder.dateDecodingStrategy)
        }
        i.bridges["set var JSONDecoder.dateDecodingStrategy: JSONDecoder.DateDecodingStrategy"] = .setter { recv, newValue in
            let decoder: JSONDecoder = try unboxOpaque(recv, as: JSONDecoder.self, typeName: "JSONDecoder")
            guard case .opaque(_, let any) = newValue,
                  let strategy = any as? JSONDecoder.DateDecodingStrategy
            else {
                throw RuntimeError.invalid("JSONDecoder.dateDecodingStrategy: expected a DateDecodingStrategy")
            }
            decoder.dateDecodingStrategy = strategy
        }
        i.bridges["var JSONDecoder.keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy"] = .computed { recv in
            let decoder: JSONDecoder = try unboxOpaque(recv, as: JSONDecoder.self, typeName: "JSONDecoder")
            return .opaque(typeName: "JSONDecoder.KeyDecodingStrategy", value: decoder.keyDecodingStrategy)
        }
        i.bridges["set var JSONDecoder.keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy"] = .setter { recv, newValue in
            let decoder: JSONDecoder = try unboxOpaque(recv, as: JSONDecoder.self, typeName: "JSONDecoder")
            guard case .opaque(_, let any) = newValue,
                  let strategy = any as? JSONDecoder.KeyDecodingStrategy
            else {
                throw RuntimeError.invalid("JSONDecoder.keyDecodingStrategy: expected a KeyDecodingStrategy")
            }
            decoder.keyDecodingStrategy = strategy
        }
    }
}

