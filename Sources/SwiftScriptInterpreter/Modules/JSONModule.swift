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
        // Encoders/Decoders carry a real Foundation instance as their
        // `.opaque` payload, so configuration set from script
        // (`outputFormatting`, `dateEncodingStrategy`, …) propagates to
        // the actual coder.
        i.bridges["JSONEncoder()"] = .`init` { _ in
            .opaque(typeName: "JSONEncoder", value: JSONEncoder())
        }
        i.bridges["JSONDecoder()"] = .`init` { _ in
            .opaque(typeName: "JSONDecoder", value: JSONDecoder())
        }
        i.bridges["PropertyListEncoder()"] = .`init` { _ in
            .opaque(typeName: "PropertyListEncoder", value: PropertyListEncoder())
        }
        i.bridges["PropertyListDecoder()"] = .`init` { _ in
            .opaque(typeName: "PropertyListDecoder", value: PropertyListDecoder())
        }

        // `encode(_:)` — same shape on every encoder type. We unwrap
        // the receiver, build a `ScriptCodable` around the value, and
        // hand it to Foundation. Strategies the user set on the
        // encoder propagate naturally because we hold the real instance.
        let encodeBody: @Sendable (Value, [Value]) async throws -> Value = { recv, args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("encode: expected 1 argument")
            }
            guard case .opaque(_, let any) = recv else {
                throw RuntimeError.invalid("encode: bad receiver")
            }
            do {
                if let enc = any as? JSONEncoder {
                    return .opaque(typeName: "Data", value: try enc.encode(ScriptCodable(args[0])))
                }
                if let enc = any as? PropertyListEncoder {
                    return .opaque(typeName: "Data", value: try enc.encode(ScriptCodable(args[0])))
                }
                throw RuntimeError.invalid("encode: unknown encoder type")
            } catch {
                throw RuntimeError.invalid("encode: \(error)")
            }
        }
        i.bridges["JSONEncoder.encode"]         = .method { try await encodeBody($0, $1) }
        i.bridges["PropertyListEncoder.encode"] = .method { try await encodeBody($0, $1) }

        // `decode(_:from:)` — symmetric. We thread the target type
        // and interpreter through `userInfo` so the bridge knows what
        // shape to coerce the JSON/PList tree into.
        let decodeBody: @Sendable (Value, [Value], Interpreter?) async throws -> Value = { recv, args, interp in
            guard let interp else {
                throw RuntimeError.invalid("decode: interpreter unavailable")
            }
            guard args.count == 2 else {
                throw RuntimeError.invalid("decode(_:from:): expected 2 arguments")
            }
            guard case .opaque(typeName: "Metatype", let typeAny) = args[0],
                  let typeName = typeAny as? String
            else {
                throw RuntimeError.invalid("decode: first argument must be a type (`T.self`)")
            }
            guard case .opaque(typeName: "Data", let dataAny) = args[1],
                  let data = dataAny as? Data
            else {
                throw RuntimeError.invalid("decode: second argument must be Data")
            }
            guard case .opaque(_, let recvAny) = recv else {
                throw RuntimeError.invalid("decode: bad receiver")
            }
            do {
                if let dec = recvAny as? JSONDecoder {
                    dec.userInfo[.scriptInterpreter] = interp
                    dec.userInfo[.scriptTargetType] = typeName
                    return try dec.decode(ScriptCodable.self, from: data).value
                }
                if let dec = recvAny as? PropertyListDecoder {
                    dec.userInfo[.scriptInterpreter] = interp
                    dec.userInfo[.scriptTargetType] = typeName
                    return try dec.decode(ScriptCodable.self, from: data).value
                }
                throw RuntimeError.invalid("decode: unknown decoder type")
            } catch {
                throw RuntimeError.invalid("decode: \(error)")
            }
        }
        i.bridges["JSONDecoder.decode"]         = .method { [weak i] in try await decodeBody($0, $1, i) }
        i.bridges["PropertyListDecoder.decode"] = .method { [weak i] in try await decodeBody($0, $1, i) }

        // Configurable strategies — surface the common ones as static
        // values on the nested types. The user assigns them to the
        // encoder/decoder via property setters wired below.
        i.bridges["JSONEncoder.OutputFormatting.prettyPrinted"] =
            .staticValue(.opaque(typeName: "JSONEncoder.OutputFormatting", value: JSONEncoder.OutputFormatting.prettyPrinted))
        i.bridges["JSONEncoder.OutputFormatting.sortedKeys"] =
            .staticValue(.opaque(typeName: "JSONEncoder.OutputFormatting", value: JSONEncoder.OutputFormatting.sortedKeys))
        i.bridges["JSONEncoder.OutputFormatting.withoutEscapingSlashes"] =
            .staticValue(.opaque(typeName: "JSONEncoder.OutputFormatting", value: JSONEncoder.OutputFormatting.withoutEscapingSlashes))
        i.bridges["JSONEncoder.DateEncodingStrategy.iso8601"] =
            .staticValue(.opaque(typeName: "JSONEncoder.DateEncodingStrategy", value: JSONEncoder.DateEncodingStrategy.iso8601))
        i.bridges["JSONEncoder.DateEncodingStrategy.secondsSince1970"] =
            .staticValue(.opaque(typeName: "JSONEncoder.DateEncodingStrategy", value: JSONEncoder.DateEncodingStrategy.secondsSince1970))
        i.bridges["JSONDecoder.DateDecodingStrategy.iso8601"] =
            .staticValue(.opaque(typeName: "JSONDecoder.DateDecodingStrategy", value: JSONDecoder.DateDecodingStrategy.iso8601))
        i.bridges["JSONDecoder.DateDecodingStrategy.secondsSince1970"] =
            .staticValue(.opaque(typeName: "JSONDecoder.DateDecodingStrategy", value: JSONDecoder.DateDecodingStrategy.secondsSince1970))

        // `String.data(using:)` — returns Data?. Hand-rolled because the
        // symbol-graph signature has a defaulted `allowLossyConversion`
        // parameter, which our generator currently treats as required.
        i.bridges["String.data"] = .method { recv, args in
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
        i.bridges["Data(_:)"] = .`init` { args in
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
        i.bridges["String.utf8"] = .computed { recv in recv }

        // `String(data:encoding:)` — failable init, returns String?.
        i.bridges["String(data:encoding:)"] = .`init` { args in
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
            i.bridges["String.Encoding.\(name)"] =
                .staticValue(.opaque(typeName: "String.Encoding", value: enc))
        }
    }
}

