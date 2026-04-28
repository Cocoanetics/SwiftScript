import Foundation
import SwiftSyntax

/// JSON encode/decode for SwiftScript values, including round-tripping
/// to user-declared structs.
///
/// ## Why we walk `Value` directly instead of using `JSONEncoder`
///
/// Real Swift's `JSONEncoder.encode(_:)` requires `Codable` conformance,
/// which the interpreter doesn't synthesize — user structs are bags of
/// `(name, Value)` fields with no Codable witness. We instead serialize
/// the `Value` tree by hand and decode JSON back into `Value`, then
/// coerce against the target type by reading the struct's declared
/// property types. The script-level surface (`JSONEncoder()`,
/// `.encode(_:)`, `JSONDecoder()`, `.decode(_:from:)`) matches Swift, so
/// scripts read identically; only the implementation differs.
///
/// ## What's covered
///   - Primitives: Int, Double, String, Bool, Optional<T>, [T]
///   - User structs: encode by walking fields; decode by matching JSON
///     keys to property names, recursing per the declared type.
///   - Type-metadata expressions (`User.self`) carrying the target name
///     for `decode(_:from:)`.
///
/// ## What's not covered (yet)
///   - Enums with associated values (Codable's standard layout is non-
///     trivial; case-only enums would be fine but aren't needed yet).
///   - Custom Codable implementations / `CodingKey` remapping.
///   - Date/URL/UUID via Foundation's built-in strategies — these would
///     round-trip through `String` if explicitly converted at the call
///     site.
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
            let json = try jsonString(from: args[0])
            return .opaque(typeName: "Data", value: Data(json.utf8))
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
            guard let s = String(data: data, encoding: .utf8) else {
                throw RuntimeError.invalid("JSONDecoder.decode: data is not valid UTF-8")
            }
            var parser = JSONParser(input: s)
            let raw = try parser.parseValue()
            try parser.expectEOF()
            return try i.coerceJSON(raw, toTypeName: typeName)
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

// MARK: - Serialization

/// Convert a Value tree to a JSON string. Throws for any value we can't
/// represent (functions, ranges, opaque-non-Data values, …).
private func jsonString(from value: Value) throws -> String {
    switch value {
    case .int(let i):    return String(i)
    case .double(let d):
        if d.isNaN || d.isInfinite {
            throw RuntimeError.invalid("JSON encoding: \(d) is not a valid number")
        }
        // Match Swift's JSONEncoder formatting for integral doubles —
        // integers print without decimals (`5`, not `5.0`).
        if d == d.rounded() && abs(d) < 1e16 {
            return String(Int64(d))
        }
        return String(d)
    case .string(let s): return jsonEscape(s)
    case .bool(let b):   return b ? "true" : "false"
    case .void:          return "null"
    case .array(let xs):
        let parts = try xs.map(jsonString(from:))
        return "[" + parts.joined(separator: ",") + "]"
    case .dict(let entries):
        // Sort by key so the output is deterministic — matches Swift's
        // `JSONEncoder` with `.outputFormatting = .sortedKeys`. Without
        // sorting we'd diverge from Foundation's nondeterministic native
        // ordering and from each other across runs.
        let pairs = try entries.map { entry -> (String, String) in
            guard case .string(let key) = entry.key else {
                throw RuntimeError.invalid("JSON encoding: dictionary keys must be strings")
            }
            return (key, try jsonString(from: entry.value))
        }
        let parts = pairs.sorted { $0.0 < $1.0 }.map {
            jsonEscape($0.0) + ":" + $0.1
        }
        return "{" + parts.joined(separator: ",") + "}"
    case .optional(let inner):
        if let inner { return try jsonString(from: inner) }
        return "null"
    case .structValue(_, let fields):
        // Same sorted-keys policy as `.dict` — the encoded form is the
        // sorted-keys canonical shape, matching Swift's
        // `outputFormatting = .sortedKeys`.
        let pairs = try fields.map { ($0.name, try jsonString(from: $0.value)) }
        let parts = pairs.sorted { $0.0 < $1.0 }.map {
            jsonEscape($0.0) + ":" + $0.1
        }
        return "{" + parts.joined(separator: ",") + "}"
    case .enumValue(_, let caseName, let payload):
        if payload.isEmpty { return jsonEscape(caseName) }
        throw RuntimeError.invalid(
            "JSON encoding: enum cases with associated values are not yet supported"
        )
    case .set(let xs):
        // Swift encodes `Set` as a JSON array. Sort by serialized form
        // for deterministic output, since the underlying iteration order
        // is implementation-defined.
        let parts = try xs.map(jsonString(from:)).sorted()
        return "[" + parts.joined(separator: ",") + "]"
    case .tuple, .range, .function, .classInstance:
        throw RuntimeError.invalid(
            "JSON encoding: type \(typeName(value)) is not encodable"
        )
    case .opaque(let n, _):
        throw RuntimeError.invalid("JSON encoding: type \(n) is not encodable")
    }
}

private func jsonEscape(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out.append("\\\"")
        case "\\": out.append("\\\\")
        case "\n": out.append("\\n")
        case "\r": out.append("\\r")
        case "\t": out.append("\\t")
        case "\u{08}": out.append("\\b")
        case "\u{0C}": out.append("\\f")
        default:
            if c.value < 0x20 {
                out.append(String(format: "\\u%04x", c.value))
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    out.append("\"")
    return out
}

// MARK: - Parser

/// Tiny recursive-descent JSON parser producing `Value` trees with these
/// shapes: `.int`/`.double`/`.string`/`.bool`/`.void` (for null) /
/// `.array`/`.dict`. Coercion to the requested target type happens later.
struct JSONParser {
    let chars: [Character]
    var pos: Int = 0

    init(input: String) {
        self.chars = Array(input)
    }

    mutating func parseValue() throws -> Value {
        skipWhitespace()
        guard pos < chars.count else {
            throw RuntimeError.invalid("JSON parse: unexpected end of input")
        }
        let c = chars[pos]
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "-", "0"..."9": return try parseNumber()
        case "t", "f": return .bool(try parseBool())
        case "n":
            try parseLiteral("null")
            return .void
        default:
            throw RuntimeError.invalid("JSON parse: unexpected character '\(c)'")
        }
    }

    mutating func expectEOF() throws {
        skipWhitespace()
        if pos < chars.count {
            throw RuntimeError.invalid("JSON parse: trailing data starting at '\(chars[pos])'")
        }
    }

    private mutating func parseObject() throws -> Value {
        try consume("{")
        skipWhitespace()
        var entries: [DictEntry] = []
        if peek() == "}" { pos += 1; return .dict(entries) }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try consume(":")
            let value = try parseValue()
            entries.append(DictEntry(key: .string(key), value: value))
            skipWhitespace()
            if peek() == "," { pos += 1; continue }
            if peek() == "}" { pos += 1; return .dict(entries) }
            throw RuntimeError.invalid("JSON parse: expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> Value {
        try consume("[")
        skipWhitespace()
        var items: [Value] = []
        if peek() == "]" { pos += 1; return .array(items) }
        while true {
            let v = try parseValue()
            items.append(v)
            skipWhitespace()
            if peek() == "," { pos += 1; continue }
            if peek() == "]" { pos += 1; return .array(items) }
            throw RuntimeError.invalid("JSON parse: expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        try consume("\"")
        var out = ""
        while pos < chars.count {
            let c = chars[pos]
            if c == "\"" { pos += 1; return out }
            if c == "\\" {
                pos += 1
                guard pos < chars.count else { break }
                switch chars[pos] {
                case "\"": out.append("\""); pos += 1
                case "\\": out.append("\\"); pos += 1
                case "/":  out.append("/"); pos += 1
                case "n":  out.append("\n"); pos += 1
                case "r":  out.append("\r"); pos += 1
                case "t":  out.append("\t"); pos += 1
                case "b":  out.append("\u{08}"); pos += 1
                case "f":  out.append("\u{0C}"); pos += 1
                case "u":
                    pos += 1
                    guard pos + 4 <= chars.count else {
                        throw RuntimeError.invalid("JSON parse: bad unicode escape")
                    }
                    let hex = String(chars[pos..<pos+4])
                    guard let code = UInt32(hex, radix: 16),
                          let scalar = Unicode.Scalar(code)
                    else {
                        throw RuntimeError.invalid("JSON parse: invalid unicode '\(hex)'")
                    }
                    out.unicodeScalars.append(scalar)
                    pos += 4
                default:
                    throw RuntimeError.invalid("JSON parse: bad escape '\(chars[pos])'")
                }
            } else {
                out.append(c)
                pos += 1
            }
        }
        throw RuntimeError.invalid("JSON parse: unterminated string")
    }

    private mutating func parseNumber() throws -> Value {
        let start = pos
        if peek() == "-" { pos += 1 }
        while pos < chars.count, chars[pos].isNumber { pos += 1 }
        var isDouble = false
        if peek() == "." {
            isDouble = true
            pos += 1
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
        }
        if peek() == "e" || peek() == "E" {
            isDouble = true
            pos += 1
            if peek() == "+" || peek() == "-" { pos += 1 }
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
        }
        let s = String(chars[start..<pos])
        if isDouble {
            guard let d = Double(s) else {
                throw RuntimeError.invalid("JSON parse: invalid number '\(s)'")
            }
            return .double(d)
        }
        guard let i = Int(s) else {
            // Probably overflowed; fall back to Double.
            guard let d = Double(s) else {
                throw RuntimeError.invalid("JSON parse: invalid number '\(s)'")
            }
            return .double(d)
        }
        return .int(i)
    }

    private mutating func parseBool() throws -> Bool {
        if peek() == "t" { try parseLiteral("true"); return true }
        try parseLiteral("false")
        return false
    }

    private mutating func parseLiteral(_ literal: String) throws {
        for ch in literal {
            guard pos < chars.count, chars[pos] == ch else {
                throw RuntimeError.invalid("JSON parse: expected '\(literal)'")
            }
            pos += 1
        }
    }

    private mutating func consume(_ c: Character) throws {
        guard pos < chars.count, chars[pos] == c else {
            throw RuntimeError.invalid("JSON parse: expected '\(c)'")
        }
        pos += 1
    }

    private mutating func skipWhitespace() {
        while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
    }

    private func peek() -> Character? {
        pos < chars.count ? chars[pos] : nil
    }
}

// MARK: - Type-driven coercion

extension Interpreter {
    /// Coerce a JSON-shaped Value into the target type. Recursion happens
    /// per the registered struct's property types — primitives pass
    /// through unchanged, optionals adopt `nil`/`some`, arrays apply the
    /// element type pointwise.
    func coerceJSON(_ value: Value, toTypeName name: String) throws -> Value {
        // Strip optional/array sugar from the type name as we recurse.
        let resolved = resolveTypeName(name)

        // Optional shape: `T?` or `Optional<T>` — we don't normalize, but
        // the dispatch site usually passes the inner name directly.
        // Array shape: `[T]` — handled by callers that walk the JSON array
        // and recurse elementwise; coerceJSON itself just routes by
        // top-level name.

        if let structDef = structDefs[resolved] {
            return try coerceJSONToStruct(value, def: structDef)
        }
        if let enumDef = enumDefs[resolved] {
            return try coerceJSONToEnum(value, def: enumDef)
        }
        // Primitive/scalar pass-through.
        return value
    }

    private func coerceJSONToStruct(_ value: Value, def: StructDef) throws -> Value {
        guard case .dict(let entries) = value else {
            throw RuntimeError.invalid(
                "JSON decode: expected object for \(def.name), got \(typeName(value))"
            )
        }
        var fields: [StructField] = []
        for prop in def.properties {
            let entryValue: Value? = entries.first(where: { e in
                if case .string(let k) = e.key { return k == prop.name }
                return false
            })?.value
            let coerced = try coerceJSONField(
                entryValue,
                typeSyntax: prop.type,
                propName: prop.name,
                ownerName: def.name
            )
            fields.append(StructField(name: prop.name, value: coerced))
        }
        return .structValue(typeName: def.name, fields: fields)
    }

    private func coerceJSONToEnum(_ value: Value, def: EnumDef) throws -> Value {
        // Bare-case enums encode as the case name (string). Raw-value
        // enums carry their rawValue — we round-trip via the rawValue.
        if let rawType = def.rawType {
            if rawType == "String" {
                guard case .string(let s) = value else {
                    throw RuntimeError.invalid(
                        "JSON decode: expected string raw value for enum \(def.name)"
                    )
                }
                if let match = def.cases.first(where: { ($0.rawValue ?? .void) == .string(s) }) {
                    return .enumValue(typeName: def.name, caseName: match.name, associatedValues: [])
                }
            }
            if rawType == "Int" {
                guard case .int(let i) = value else {
                    throw RuntimeError.invalid(
                        "JSON decode: expected integer raw value for enum \(def.name)"
                    )
                }
                if let match = def.cases.first(where: { ($0.rawValue ?? .void) == .int(i) }) {
                    return .enumValue(typeName: def.name, caseName: match.name, associatedValues: [])
                }
            }
            throw RuntimeError.invalid(
                "JSON decode: no matching case for raw value in enum \(def.name)"
            )
        }
        // No raw type: encode as case name string.
        guard case .string(let s) = value else {
            throw RuntimeError.invalid(
                "JSON decode: expected case name for enum \(def.name)"
            )
        }
        if def.cases.contains(where: { $0.name == s }) {
            return .enumValue(typeName: def.name, caseName: s, associatedValues: [])
        }
        throw RuntimeError.invalid(
            "JSON decode: '\(s)' is not a case of \(def.name)"
        )
    }

    /// Coerce a single field, handling Optional wrapping, Array element
    /// recursion, and nested struct/enum dispatch.
    private func coerceJSONField(
        _ value: Value?,
        typeSyntax: TypeSyntax?,
        propName: String,
        ownerName: String
    ) throws -> Value {
        let typeText = typeSyntax?.description.trimmingCharacters(in: .whitespaces) ?? ""
        // Optional: `T?` — accept missing / null as nil.
        if typeText.hasSuffix("?") {
            let inner = String(typeText.dropLast())
            if value == nil || value == .void {
                return .optional(nil)
            }
            let coerced = try coerceJSON(value!, toTypeName: inner)
            return .optional(coerced)
        }
        guard let value else {
            throw RuntimeError.invalid(
                "JSON decode: missing key '\(propName)' for \(ownerName)"
            )
        }
        if value == .void {
            // Non-optional field can't be null.
            throw RuntimeError.invalid(
                "JSON decode: null for non-optional field '\(propName)' on \(ownerName)"
            )
        }
        // Array: `[T]`.
        if typeText.hasPrefix("[") && typeText.hasSuffix("]") && !typeText.contains(":") {
            let inner = String(typeText.dropFirst().dropLast())
            guard case .array(let items) = value else {
                throw RuntimeError.invalid(
                    "JSON decode: expected array for '\(propName)' on \(ownerName)"
                )
            }
            let coerced = try items.map { try coerceJSON($0, toTypeName: inner) }
            return .array(coerced)
        }
        // Bare-name: dispatch by registered type.
        if !typeText.isEmpty {
            return try coerceJSON(value, toTypeName: typeText)
        }
        return value
    }
}
