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
        // JSONEncoder/JSONDecoder are sentinel-shaped — a `.structValue`
        // with a known typeName, no fields. They have no real state today.
        i.registerInit(on: "JSONEncoder", labels: []) { _ in
            return .structValue(typeName: "JSONEncoder", fields: [])
        }
        i.registerInit(on: "JSONDecoder", labels: []) { _ in
            return .structValue(typeName: "JSONDecoder", fields: [])
        }
        i.registerMethod(on: "JSONEncoder", name: "encode") { _, args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("JSONEncoder.encode: expected 1 argument")
            }
            let encoder = JSONEncoder()
            // Match Swift's default ordering: declaration order from
            // synthesized Encodable. The bridge already walks fields in
            // that order, but the encoder may otherwise stable-sort if
            // we don't pin this.
            encoder.outputFormatting = []
            do {
                let data = try encoder.encode(ScriptCodable(args[0]))
                return .opaque(typeName: "Data", value: data)
            } catch {
                throw RuntimeError.invalid("JSONEncoder.encode: \(error)")
            }
        }
        // Capture `self` so the decode closure can read interpreter state
        // (structDefs, enumDefs) for type-driven coercion.
        i.registerMethod(on: "JSONDecoder", name: "decode") { [weak i] _, args in
            guard let i else {
                throw RuntimeError.invalid("JSONDecoder.decode: interpreter unavailable")
            }
            guard args.count == 2 else {
                throw RuntimeError.invalid(
                    "JSONDecoder.decode(_:from:): expected 2 arguments"
                )
            }
            guard case .opaque(typeName: "Metatype", let any) = args[0],
                  let typeName = any as? String
            else {
                throw RuntimeError.invalid(
                    "JSONDecoder.decode: first argument must be a type (`T.self`)"
                )
            }
            guard case .opaque(typeName: "Data", let dataAny) = args[1],
                  let data = dataAny as? Data
            else {
                throw RuntimeError.invalid(
                    "JSONDecoder.decode: second argument must be Data"
                )
            }
            let decoder = JSONDecoder()
            decoder.userInfo[.scriptInterpreter] = i
            decoder.userInfo[.scriptTargetType] = typeName
            do {
                let wrapper = try decoder.decode(ScriptCodable.self, from: data)
                return wrapper.value
            } catch {
                throw RuntimeError.invalid("JSONDecoder.decode: \(error)")
            }
        }

        // `String.data(using:)` — returns Data?. Hand-rolled because the
        // symbol-graph signature has a defaulted `allowLossyConversion`
        // parameter, which our generator currently treats as required.
        i.registerMethod(on: "String", name: "data") { recv, args in
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
        i.registerInit(on: "Data", labels: ["_"]) { args in
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
        // `String.utf8` — model as a pass-through to the receiver string.
        // Real Swift returns `String.UTF8View` (a sequence of bytes); for
        // our purposes the only common consumer is `Data(_:)` above, which
        // accepts `.string` directly.
        i.registerComputed(on: "String", name: "utf8") { recv in recv }

        // `String(data:encoding:)` — failable init, returns String?.
        i.registerInit(on: "String", labels: ["data", "encoding"]) { args in
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
            i.registerStaticValue(
                on: "String.Encoding",
                name: name,
                value: .opaque(typeName: "String.Encoding", value: enc)
            )
        }
    }
}

