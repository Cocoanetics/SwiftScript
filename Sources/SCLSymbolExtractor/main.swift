// SCLSymbolExtractor — walk a swift-corelibs-foundation source tree
// (or any other Swift package's source) and emit a flat list of every
// public type member it declares. The bridge generator consumes this
// list to classify each Apple-side bridge entry as cross-platform or
// Apple-only — entries that aren't present in the scl extract get
// gated behind `#if canImport(Darwin)` automatically, eliminating the
// hand-curated `+Apple.swift` companions that used to be required.
//
// Output format (one symbol per line):
//
//   Type.memberName                       (cross-platform)
//   Type.memberName  UNAVAILABLE          (declared but @available(*, unavailable))
//
// The matching is name-only (no signature) — overloads collapse into
// one entry. That's intentional: the generator only needs to answer
// "does Linux have *some* form of this member?", not "does the exact
// overload exist?". Cases where Apple has an overload Linux doesn't
// (e.g. URL initializers) are rare and surface as a CI build failure
// caught immediately.
import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - CLI parsing

struct CLI {
    var sourceDirs: [URL] = []
    var output: URL?
}

var cli = CLI()
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--source":
        guard let path = args.next() else {
            FileHandle.standardError.write(Data("missing value for --source\n".utf8))
            exit(2)
        }
        cli.sourceDirs.append(URL(fileURLWithPath: path))
    case "--output":
        guard let path = args.next() else {
            FileHandle.standardError.write(Data("missing value for --output\n".utf8))
            exit(2)
        }
        cli.output = URL(fileURLWithPath: path)
    default:
        FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
        exit(2)
    }
}
if cli.sourceDirs.isEmpty || cli.output == nil {
    FileHandle.standardError.write(Data("""
        usage: SCLSymbolExtractor --source <dir> [--source <dir> ...] --output <path>

        Walks each --source directory recursively, parses every .swift file
        with SwiftSyntax, and writes the public-member set to --output.
        """.utf8))
    exit(2)
}

// MARK: - Visitor

/// Per-symbol record — one Type.memberName per line of output.
struct SymbolRecord: Hashable, Comparable {
    let typeName: String
    let memberName: String
    /// True when the declaration carries `@available(*, unavailable, ...)`.
    /// Treated as "not present on Linux" by the bridge classifier even
    /// though the symbol exists in source — scl marks intentionally-
    /// unimplemented APIs this way.
    let unavailable: Bool

    static func < (lhs: SymbolRecord, rhs: SymbolRecord) -> Bool {
        if lhs.typeName != rhs.typeName { return lhs.typeName < rhs.typeName }
        return lhs.memberName < rhs.memberName
    }
}

final class PublicMemberVisitor: SyntaxVisitor {
    /// Stack of enclosing type names (`["URLSession", "DataTaskPublisher"]`
    /// for a method on a nested type). Used to qualify member names with
    /// their dotted owning-type path.
    private var typeStack: [String] = []
    /// Set of records collected so far. Keyed for dedup of overloads.
    var records: Set<SymbolRecord> = []

    /// Whether a declaration's modifier list grants public/open access.
    /// `internal`/`fileprivate`/`private` are skipped — bridge generator
    /// only emits `public` symbols, so we mirror that filter.
    private static func isPublic(_ modifiers: DeclModifierListSyntax?) -> Bool {
        guard let modifiers else { return false }
        for m in modifiers {
            switch m.name.tokenKind {
            case .keyword(.public), .keyword(.open): return true
            case .keyword(.internal), .keyword(.fileprivate), .keyword(.private):
                return false
            default: continue
            }
        }
        return false
    }

    /// Detect `@available(*, unavailable, ...)` on a declaration. scl
    /// uses this to mark APIs that exist on Apple but aren't ported.
    private static func isUnavailable(_ attributes: AttributeListSyntax?) -> Bool {
        guard let attributes else { return false }
        for attr in attributes {
            guard case .attribute(let a) = attr,
                  let id = a.attributeName.as(IdentifierTypeSyntax.self),
                  id.name.text == "available",
                  let args = a.arguments?.as(AvailabilityArgumentListSyntax.self)
            else { continue }
            for arg in args {
                if case .token(let t) = arg.argument,
                   t.tokenKind == .keyword(.unavailable)
                {
                    return true
                }
            }
        }
        return false
    }

    private func push(_ name: String) { typeStack.append(name) }
    private func pop() { _ = typeStack.popLast() }

    /// Resolve the dotted owner type. For a top-level decl this is the
    /// outermost `extension`/`struct`/`class` name; for a nested decl
    /// it walks the full stack.
    private func currentTypeName() -> String? {
        typeStack.isEmpty ? nil : typeStack.joined(separator: ".")
    }

    private func record(_ memberName: String, unavailable: Bool) {
        guard let owner = currentTypeName() else { return }
        records.insert(SymbolRecord(
            typeName: owner, memberName: memberName, unavailable: unavailable
        ))
    }

    // MARK: Type containers (push/pop type stack)

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { pop() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { pop() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { pop() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { pop() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // The extended type is whatever the parser saw to the right of
        // `extension`. Strip generic clauses and the `where` body —
        // we just want the dotted name (`URLSession.DataTaskPublisher`).
        let raw = node.extendedType.trimmedDescription
            .components(separatedBy: "<").first ?? ""
        push(raw.trimmingCharacters(in: .whitespaces))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { pop() }

    // MARK: Members

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isPublic(node.modifiers) {
            record(node.name.text,
                   unavailable: Self.isUnavailable(node.attributes))
        }
        return .visitChildren  // walk into body for nested types
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isPublic(node.modifiers) {
            let unavail = Self.isUnavailable(node.attributes)
            for binding in node.bindings {
                if let id = binding.pattern.as(IdentifierPatternSyntax.self) {
                    record(id.identifier.text, unavailable: unavail)
                }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isPublic(node.modifiers) {
            record("init", unavailable: Self.isUnavailable(node.attributes))
        }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if Self.isPublic(node.modifiers) {
            record("subscript", unavailable: Self.isUnavailable(node.attributes))
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        // Nested typealias counts as a member; top-level typealias gets
        // recorded with no owner and is dropped by `record(...)`.
        if Self.isPublic(node.modifiers) {
            record(node.name.text,
                   unavailable: Self.isUnavailable(node.attributes))
        }
        return .visitChildren
    }
}

// MARK: - Driver

func enumerateSwiftFiles(under url: URL) -> [URL] {
    let fm = FileManager.default
    guard let it = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
        return []
    }
    var result: [URL] = []
    for case let f as URL in it where f.pathExtension == "swift" {
        result.append(f)
    }
    return result
}

let visitor = PublicMemberVisitor(viewMode: .sourceAccurate)
var fileCount = 0
for dir in cli.sourceDirs {
    for fileURL in enumerateSwiftFiles(under: dir) {
        guard let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .utf8)
        else { continue }
        let tree = Parser.parse(source: source)
        visitor.walk(tree)
        fileCount += 1
    }
}

// Sort + serialize. UNAVAILABLE marker lets the consumer treat scl-
// declared-but-unavailable symbols as Apple-only.
var lines: [String] = []
for record in visitor.records.sorted() {
    let key = "\(record.typeName).\(record.memberName)"
    lines.append(record.unavailable ? "\(key)\tUNAVAILABLE" : key)
}
let payload = lines.joined(separator: "\n") + "\n"
let outputURL = cli.output!
do {
    try payload.write(to: outputURL, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data(
        "wrote \(visitor.records.count) symbols from \(fileCount) source file(s) → \(outputURL.path)\n".utf8
    ))
} catch {
    FileHandle.standardError.write(Data("error writing output: \(error)\n".utf8))
    exit(1)
}
