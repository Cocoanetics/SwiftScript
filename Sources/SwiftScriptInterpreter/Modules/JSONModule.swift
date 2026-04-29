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
        // `String.utf8` — model as a pass-through to the receiver string.
        // Real Swift returns `String.UTF8View` (a sequence of bytes); for
        // our purposes the only common consumer is `Data(_:)` above, which
        // accepts `.string` directly.
        i.bridges["var String.utf8"] = .computed { recv in recv }

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
    }
}

