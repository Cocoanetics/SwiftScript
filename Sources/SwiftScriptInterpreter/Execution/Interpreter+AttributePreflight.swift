import SwiftSyntax

// MARK: - Unsupported-attribute preflight
//
// The interpreter never honors declaration attributes, so any
// attribute whose *absence of semantics* would change a program's
// output must be refused up front. The canonical offenders are
// `@propertyWrapper` and `@resultBuilder`: accepting the declaration
// and ignoring the semantics silently produces a different value than
// stock Swift (the wrapper's setter never runs; only a builder
// block's last statement survives). A loud boundary error beats a
// plausible wrong answer — especially for generated code nobody
// reads line by line.

/// Declaration attributes the interpreter may ignore without the
/// program's *output* diverging from stock Swift. Availability,
/// optimization, interop, and concurrency-isolation annotations
/// change how code is scheduled or compiled, not what a script
/// computes. Anything not listed here — `@propertyWrapper`,
/// `@resultBuilder`, and every custom attribute (`@Clamped`,
/// `@State`, attached macros) — is refused.
private let ignorableDeclAttributes: Set<String> = [
    "available", "backDeployed",
    "discardableResult", "warn_unqualified_access",
    "inline", "inlinable", "usableFromInline", "transparent",
    "frozen", "preconcurrency", "retroactive",
    "objc", "objcMembers", "nonobjc",
    "MainActor", "Sendable", "unchecked",
    "escaping", "autoclosure", "convention",
    // Honored implicitly: dynamic-member lookup works off the
    // presence of a `subscript(dynamicMember:)` declaration, and a
    // missing `@dynamicCallable` implementation fails loudly at the
    // call site ("has no member dynamicallyCall"), never silently.
    "dynamicMemberLookup", "dynamicCallable",
]

/// Walks a parsed source file and records the first declaration
/// attribute the interpreter cannot honor. Type-position attributes
/// (`@escaping`, `@Sendable` inside a function type) are exempt —
/// they constrain the type system, not runtime behavior. Attributes
/// the host registered via `registerAttribute` (`@Test`, `@Suite`)
/// are exempt too — the host declared it knows their semantics.
final class UnsupportedAttributeScanner: SyntaxVisitor {
    private(set) var offense: (name: String, offset: Int, reason: String)?
    private let hostRegistered: Set<String>

    private init(hostRegistered: Set<String>) {
        self.hostRegistered = hostRegistered
        super.init(viewMode: .sourceAccurate)
    }

    static func firstOffense(
        in file: SourceFileSyntax,
        allowing hostRegistered: Set<String> = []
    ) -> (name: String, offset: Int, reason: String)? {
        let scanner = UnsupportedAttributeScanner(hostRegistered: hostRegistered)
        scanner.walk(file)
        return scanner.offense
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if offense != nil { return .skipChildren }
        // Only *declaration* attributes are in scope. A declaration
        // attribute sits in an `AttributeListSyntax` whose parent is
        // the declaration itself. Everything else is fine to ignore:
        //   - type-position attributes (`@escaping`, `@Sendable` in a
        //     function type) hang off `AttributedTypeSyntax`;
        //   - `@unknown` on a `switch` default and other statement /
        //     closure / switch-case attributes have no runtime
        //     semantics and stock Swift accepts them.
        guard node.parent?.parent?.asProtocol(DeclSyntaxProtocol.self) != nil
        else {
            return .skipChildren
        }
        let name = node.attributeName.description
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        switch name {
        case _ where ignorableDeclAttributes.contains(name)
            || hostRegistered.contains(name):
            break
        case "propertyWrapper":
            offense = (name, offset,
                "property-wrapper semantics (wrappedValue storage, the "
                + "wrapper's accessors, $-projections) are not implemented — "
                + "the raw value would be stored and the program would "
                + "silently compute a different result than stock Swift")
        case "resultBuilder":
            offense = (name, offset,
                "result-builder transforms (buildBlock/buildExpression) are "
                + "not implemented — only the last statement of a builder "
                + "block would survive, silently diverging from stock Swift")
        default:
            offense = (name, offset,
                "custom attributes (property wrappers, attached macros) are "
                + "not implemented — the attribute would be ignored and the "
                + "program could silently diverge from stock Swift")
        }
        return .skipChildren
    }
}

extension Interpreter {
    /// Refuse any source file whose declarations carry attributes the
    /// interpreter would otherwise silently ignore. Called from
    /// ``eval(_:fileName:)`` after parsing, before execution.
    func rejectUnsupportedAttributes(in file: SourceFileSyntax) throws {
        if let offense = UnsupportedAttributeScanner.firstOffense(
            in: file, allowing: registeredAttributes
        ) {
            throw RuntimeError.unsupported(
                "attribute '@\(offense.name)': \(offense.reason)",
                at: offense.offset
            )
        }
    }
}
