import Foundation

/// Minimal subset of the Apple symbol-graph schema (format v0.6) — only the
/// fields we actually consult. Spec:
/// https://github.com/apple/swift/blob/main/lib/SymbolGraphGen/Format.md
struct SymbolGraph: Decodable {
    let module: ModuleInfo
    let symbols: [Symbol]
    let relationships: [Relationship]?

    struct ModuleInfo: Decodable {
        let name: String
    }

    struct Symbol: Decodable {
        let kind: Kind
        let identifier: Identifier
        let pathComponents: [String]
        let names: Names
        let functionSignature: FunctionSignature?
        /// Top-level fragments for the symbol's declaration. For type
        /// properties (e.g. `CharacterSet.whitespaces`) this is where the
        /// property type appears (functions use `functionSignature`).
        let declarationFragments: [Fragment]?
        /// Availability annotations — `@available(*, deprecated)` etc.
        /// Used to skip retired API at harvest time.
        let availability: [Availability]?
        let swiftGenerics: SwiftGenerics?

        struct SwiftGenerics: Decodable {
            let parameters: [GenericParameter]?
            let constraints: [Constraint]?
            struct GenericParameter: Decodable {
                let name: String
            }
            struct Constraint: Decodable {
                let kind: String         // "conformance" | "sameType" | "superclass"
                let lhs: String
                let rhs: String
            }
        }

        struct Availability: Decodable {
            let domain: String?
            let introduced: Version?
            let deprecated: Version?
            let obsoleted: Version?
            let isUnconditionallyDeprecated: Bool?
            let isUnconditionallyUnavailable: Bool?

            struct Version: Decodable {
                let major: Int?
                let minor: Int?
                let patch: Int?
            }
        }

        struct Kind: Decodable {
            let identifier: String  // "swift.func", "swift.method", "swift.var", "swift.init"
        }
        struct Identifier: Decodable {
            let precise: String  // USR
        }
        struct Names: Decodable {
            let title: String  // e.g. "sqrt(_:)"
        }
        struct FunctionSignature: Decodable {
            let parameters: [Parameter]?
            let returns: [Fragment]?

            struct Parameter: Decodable {
                /// In symbol-graph schema, `name` is the *external label*
                /// when present, or the param name when there's no
                /// distinct label. The actual call-site labels (including
                /// `_` for unlabelled) come from the parent symbol's
                /// title — `argLabels(fromTitle:)` does that parsing.
                let name: String
                let declarationFragments: [Fragment]
            }
        }
    }

    struct Fragment: Decodable {
        let kind: String
        let spelling: String
        let preciseIdentifier: String?
    }

    struct Relationship: Decodable {
        let kind: String     // "memberOf", "conformsTo", …
        let source: String   // USR
        let target: String   // USR
    }
}
