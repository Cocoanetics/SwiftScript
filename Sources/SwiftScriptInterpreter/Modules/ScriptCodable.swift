import Foundation

/// `Codable` bridge for the interpreter's `Value` tree. Wrapping a script
/// value in `ScriptCodable` lets any host `Encoder`/`Decoder`
/// (`JSONEncoder`, `PropertyListEncoder`, …) round-trip it through
/// Swift's real Codable machinery — we don't reimplement format
/// quirks or `Date`/`URL` strategies; Foundation does that work.
///
/// ## Direction-specific contract
///
/// - **Encoding** is symmetric: walk the `Value`, ask the encoder for
///   the matching container kind, recurse. No type context needed.
/// - **Decoding** needs to know the target shape (JSON `{}` could be
///   any struct, JSON `null` could be any optional). The caller
///   passes the script type name through `decoder.userInfo` under
///   `CodingUserInfoKey.scriptTargetType`, plus the `Interpreter`
///   under `.scriptInterpreter` so we can consult `structDefs` etc.
public struct ScriptCodable: Codable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        try Self.encodeValue(value, to: encoder)
    }

    public init(from decoder: Decoder) throws {
        guard let interp = decoder.userInfo[.scriptInterpreter] as? Interpreter,
              let typeName = decoder.userInfo[.scriptTargetType] as? String
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "ScriptCodable requires .scriptInterpreter and .scriptTargetType in decoder.userInfo"
            ))
        }
        self.value = try Self.decodeValue(
            from: decoder, typeName: typeName, interp: interp
        )
    }

    // MARK: - Encode

    static func encodeValue(_ value: Value, to encoder: Encoder) throws {
        switch value {
        case .int(let n):
            var c = encoder.singleValueContainer(); try c.encode(n)
        case .double(let d):
            var c = encoder.singleValueContainer(); try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .void:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .optional(nil):
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .optional(.some(let inner)):
            try encodeValue(inner, to: encoder)
        case .array(let xs), .set(let xs):
            var c = encoder.unkeyedContainer()
            for el in xs {
                try encodeValue(el, to: c.superEncoder())
            }
        case .dict(let entries):
            // Top-level `[K: V]`. We require String keys — that's all
            // JSON / PList can express anyway.
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            for entry in entries {
                guard case .string(let k) = entry.key else {
                    throw EncodingError.invalidValue(entry.key, .init(
                        codingPath: c.codingPath,
                        debugDescription: "dictionary key must be String for Codable"
                    ))
                }
                try encodeValue(entry.value, to: c.superEncoder(forKey: AnyCodingKey(stringValue: k)!))
            }
        case .structValue(_, let fields):
            // Declaration-order encoding; nil-valued optionals omitted —
            // matching Swift's synthesized `Encodable` conformance.
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            for f in fields {
                if case .optional(nil) = f.value { continue }
                try encodeValue(f.value, to: c.superEncoder(forKey: AnyCodingKey(stringValue: f.name)!))
            }
        case .enumValue(_, let caseName, let payload):
            // Payload-less cases encode as the case name string —
            // matches Swift's default for `enum E: String`.
            // Cases with associated values use Swift's standard
            // single-key shape: `{ "caseName": [args...] }`.
            if payload.isEmpty {
                var c = encoder.singleValueContainer()
                try c.encode(caseName)
            } else {
                var c = encoder.container(keyedBy: AnyCodingKey.self)
                var inner = c.nestedUnkeyedContainer(forKey: AnyCodingKey(stringValue: caseName)!)
                for arg in payload {
                    try encodeValue(arg, to: inner.superEncoder())
                }
            }
        case .opaque(let opaqueType, let any):
            // Foundation types delegate to their own Codable
            // conformance — we just hand the host value to a
            // single-value container of the right type.
            var c = encoder.singleValueContainer()
            switch (opaqueType, any) {
            case ("Date", let v as Date):     try c.encode(v)
            case ("URL", let v as URL):       try c.encode(v)
            case ("UUID", let v as UUID):     try c.encode(v)
            case ("Data", let v as Data):     try c.encode(v)
            case ("Decimal", let v as Decimal): try c.encode(v)
            default:
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "no Codable bridge for opaque type '\(opaqueType)'"
                ))
            }
        case .range, .tuple, .function, .classInstance:
            throw EncodingError.invalidValue(value, .init(
                codingPath: encoder.codingPath,
                debugDescription: "type \(typeName(value)) is not Codable"
            ))
        }
    }

    // MARK: - Decode

    static func decodeValue(
        from decoder: Decoder,
        typeName rawTypeName: String,
        interp: Interpreter
    ) throws -> Value {
        let typeName = rawTypeName.trimmingCharacters(in: .whitespaces)

        // `T?` / `Optional<T>` — try `decodeNil`; recurse on inner if not.
        if typeName.hasSuffix("?") {
            let inner = String(typeName.dropLast())
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                return .optional(nil)
            }
            return .optional(try decodeValue(from: decoder, typeName: inner, interp: interp))
        }
        if typeName.hasPrefix("Optional<") && typeName.hasSuffix(">") {
            let inner = String(typeName.dropFirst("Optional<".count).dropLast())
            return try decodeValue(
                from: decoder,
                typeName: "\(inner)?",
                interp: interp
            )
        }

        // `[T]` — unkeyed container, recurse element-wise.
        if typeName.hasPrefix("[") && typeName.hasSuffix("]") && !typeName.contains(":") {
            let inner = String(typeName.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            var c = try decoder.unkeyedContainer()
            var elements: [Value] = []
            while !c.isAtEnd {
                let elDec = try c.superDecoder()
                elements.append(try decodeValue(from: elDec, typeName: inner, interp: interp))
            }
            return .array(elements)
        }

        // `[K: V]` — keyed container.
        if typeName.hasPrefix("[") && typeName.contains(":") && typeName.hasSuffix("]") {
            let body = String(typeName.dropFirst().dropLast())
            let parts = body.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "malformed dictionary type '\(typeName)'"
                ))
            }
            let valueType = String(parts[1])
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            var entries: [DictEntry] = []
            for key in c.allKeys {
                let nested = try c.superDecoder(forKey: key)
                let v = try decodeValue(from: nested, typeName: valueType, interp: interp)
                entries.append(DictEntry(key: .string(key.stringValue), value: v))
            }
            return .dict(entries)
        }

        // Resolve through typealiases.
        let resolved = interp.resolveTypeName(typeName)

        // Struct — keyed container against the def's stored properties.
        if let def = interp.structDefs[resolved] {
            return try decodeStruct(from: decoder, def: def, interp: interp)
        }

        // Enum — raw value (single-value container) or payload-less.
        if let def = interp.enumDefs[resolved] {
            return try decodeEnum(from: decoder, def: def)
        }

        // Stdlib / Foundation singles.
        let single = try decoder.singleValueContainer()
        switch resolved {
        case "Int":     return .int(try single.decode(Int.self))
        case "Double":  return .double(try single.decode(Double.self))
        case "Float":   return .double(Double(try single.decode(Float.self)))
        case "String":  return .string(try single.decode(String.self))
        case "Bool":    return .bool(try single.decode(Bool.self))
        case "Date":    return .opaque(typeName: "Date",    value: try single.decode(Date.self))
        case "URL":     return .opaque(typeName: "URL",     value: try single.decode(URL.self))
        case "UUID":    return .opaque(typeName: "UUID",    value: try single.decode(UUID.self))
        case "Data":    return .opaque(typeName: "Data",    value: try single.decode(Data.self))
        case "Decimal": return .opaque(typeName: "Decimal", value: try single.decode(Decimal.self))
        default:
            throw DecodingError.typeMismatch(
                ScriptCodable.self,
                .init(codingPath: decoder.codingPath,
                      debugDescription: "no decoder for type '\(typeName)'")
            )
        }
    }

    private static func decodeStruct(
        from decoder: Decoder, def: StructDef, interp: Interpreter
    ) throws -> Value {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var fields: [StructField] = []
        for prop in def.properties {
            let key = AnyCodingKey(stringValue: prop.name)!
            let propTypeStr = prop.type?
                .description.trimmingCharacters(in: .whitespaces) ?? "Any"
            let isOptional = propTypeStr.hasSuffix("?")
                || propTypeStr.hasPrefix("Optional<")
            // Missing key on an optional field decodes to nil — Swift's
            // synthesized Decodable does the same when the key is
            // absent from the JSON.
            if !c.contains(key) {
                if isOptional {
                    fields.append(StructField(name: prop.name, value: .optional(nil)))
                    continue
                }
                throw DecodingError.keyNotFound(key, .init(
                    codingPath: c.codingPath,
                    debugDescription: "missing key '\(prop.name)' on \(def.name)"
                ))
            }
            // Explicit null on an optional field is also nil.
            if isOptional, try c.decodeNil(forKey: key) {
                fields.append(StructField(name: prop.name, value: .optional(nil)))
                continue
            }
            let nested = try c.superDecoder(forKey: key)
            let inner = isOptional
                ? (propTypeStr.hasSuffix("?")
                    ? String(propTypeStr.dropLast())
                    : String(propTypeStr.dropFirst("Optional<".count).dropLast()))
                : propTypeStr
            let inner2 = inner.trimmingCharacters(in: .whitespaces)
            let decoded = try decodeValue(from: nested, typeName: inner2, interp: interp)
            fields.append(StructField(
                name: prop.name,
                value: isOptional ? .optional(decoded) : decoded
            ))
        }
        return .structValue(typeName: def.name, fields: fields)
    }

    private static func decodeEnum(
        from decoder: Decoder, def: EnumDef
    ) throws -> Value {
        let c = try decoder.singleValueContainer()
        // Raw-value enums: decode the rawType and find the matching case.
        if def.rawType == "String" {
            let s = try c.decode(String.self)
            // Try as case name first; fall back to matching `rawValue`.
            if def.cases.contains(where: { $0.name == s }) {
                return .enumValue(typeName: def.name, caseName: s, associatedValues: [])
            }
            if let m = def.cases.first(where: {
                if case .string(let v) = $0.rawValue ?? .void { return v == s } else { return false }
            }) {
                return .enumValue(typeName: def.name, caseName: m.name, associatedValues: [])
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "no case in \(def.name) matches '\(s)'"
            ))
        }
        if def.rawType == "Int" {
            let n = try c.decode(Int.self)
            if let m = def.cases.first(where: {
                if case .int(let v) = $0.rawValue ?? .void { return v == n } else { return false }
            }) {
                return .enumValue(typeName: def.name, caseName: m.name, associatedValues: [])
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "no case in \(def.name) matches \(n)"
            ))
        }
        // Payload-less enum without a raw type: decode the case name.
        let s = try c.decode(String.self)
        guard def.cases.contains(where: { $0.name == s }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "no case '\(s)' in \(def.name)"
            ))
        }
        return .enumValue(typeName: def.name, caseName: s, associatedValues: [])
    }
}

// MARK: - Coding key + userInfo plumbing

extension CodingUserInfoKey {
    /// `Interpreter` reference, used by `ScriptCodable` to consult
    /// `structDefs` / `enumDefs` during decoding.
    public static let scriptInterpreter = CodingUserInfoKey(rawValue: "swiftScript.interpreter")!
    /// Type name (e.g. `"Settings"`, `"[Settings]"`, `"User?"`) the
    /// caller wants the JSON tree to be coerced into.
    public static let scriptTargetType = CodingUserInfoKey(rawValue: "swiftScript.targetType")!
}

/// Coding key that accepts any string — needed because struct field
/// names are dynamic, and Swift's synthesized `CodingKeys` enum
/// expects a fixed set we don't have at compile time.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}
