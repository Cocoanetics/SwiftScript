import Foundation

/// `Mirror(reflecting:)` bridge — exposes the structural shape of a
/// `Value` so script code can write generic dump helpers, debug
/// printers, and data-driven serializers without per-type wiring.
///
/// Children are `(label?, Value)` tuples surfaced as a `[String?]`-
/// labeled array of `Value` tuples; matches the shape of Swift's
/// `Mirror.Children` closely enough that idiomatic uses (`for child
/// in mirror.children`) port directly.
struct MirrorModule: BuiltinModule {
    let name = "Mirror"

    func register(into i: Interpreter) {
        // `Mirror(reflecting: x)` — single-arg init with the labeled
        // form. The bridge stores the reflected value so children /
        // displayStyle can be computed lazily.
        i.bridges["init Mirror(reflecting:)"] = .`init` { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Mirror(reflecting:): expected 1 argument")
            }
            let box = MirrorBox(reflected: args[0])
            return .opaque(typeName: "Mirror", value: box)
        }

        // `Mirror.children` — `[(label: String?, value: Any)]`. Encoded
        // as an array of 2-tuples so script code can pattern-match
        // (label, value) directly.
        i.bridges["var Mirror.children"] = .computed { recv in
            guard case .opaque(_, let any) = recv,
                  let box = any as? MirrorBox
            else {
                throw RuntimeError.invalid("Mirror.children: bad receiver")
            }
            return .array(MirrorModule.childrenOf(box.reflected))
        }

        // `Mirror.displayStyle` — `Mirror.DisplayStyle?`. Returns the
        // simplest hint about the reflected shape: `.struct`, `.class`,
        // `.enum`, `.tuple`, `.collection`, `.dictionary`, `.set`,
        // `.optional`, or nil for atomic primitives.
        i.bridges["var Mirror.displayStyle"] = .computed { recv in
            guard case .opaque(_, let any) = recv,
                  let box = any as? MirrorBox
            else { return .optional(nil) }
            guard let style = MirrorModule.displayStyle(box.reflected) else {
                return .optional(nil)
            }
            return .optional(.string(style))
        }

        // `Mirror.subjectType` — type name as a String. Real Swift
        // returns an `Any.Type`; we surface the textual form which is
        // what most idiomatic uses inspect.
        i.bridges["var Mirror.subjectType"] = .computed { recv in
            guard case .opaque(_, let any) = recv,
                  let box = any as? MirrorBox
            else { return .string("?") }
            return .string(typeName(box.reflected))
        }
    }

    /// Build a `[(label, value)]` array for the reflected value.
    /// Tuples surface their labels (or `nil` if absent); structs and
    /// classes surface field names; enums report the case name as the
    /// label of the payload tuple.
    static func childrenOf(_ value: Value) -> [Value] {
        switch value {
        case .structValue(_, let fields):
            return fields.map {
                .tuple([.optional(.string($0.name)), $0.value], labels: ["label", "value"])
            }
        case .classInstance(let inst):
            return inst.fields.map {
                .tuple([.optional(.string($0.name)), $0.value], labels: ["label", "value"])
            }
        case .tuple(let elements, let labels):
            return zip(0..<elements.count, elements).map { idx, value in
                let label: Value
                if labels.indices.contains(idx), let l = labels[idx] {
                    label = .optional(.string(l))
                } else {
                    label = .optional(nil)
                }
                return .tuple([label, value], labels: ["label", "value"])
            }
        case .array(let xs), .set(let xs):
            return xs.map {
                .tuple([.optional(nil), $0], labels: ["label", "value"])
            }
        case .dict(let entries):
            return entries.map {
                .tuple([.optional(nil), .tuple([$0.key, $0.value], labels: ["key", "value"])],
                       labels: ["label", "value"])
            }
        case .enumValue(_, let caseName, let payload):
            if payload.isEmpty {
                return []
            }
            return [.tuple([.optional(.string(caseName)),
                            .tuple(payload, labels: [])],
                           labels: ["label", "value"])]
        case .optional(.some(let inner)):
            return [.tuple([.optional(.string("some")), inner],
                           labels: ["label", "value"])]
        default:
            return []
        }
    }

    static func displayStyle(_ value: Value) -> String? {
        switch value {
        case .structValue:        return "struct"
        case .classInstance:      return "class"
        case .enumValue:          return "enum"
        case .tuple:              return "tuple"
        case .array:              return "collection"
        case .dict:               return "dictionary"
        case .set:                return "set"
        case .optional:           return "optional"
        default:                  return nil
        }
    }
}

/// Reference cell so `Mirror` reads lazy across `.children`,
/// `.displayStyle`, etc. without re-walking the value each access.
final class MirrorBox: @unchecked Sendable {
    let reflected: Value
    init(reflected: Value) { self.reflected = reflected }
}
