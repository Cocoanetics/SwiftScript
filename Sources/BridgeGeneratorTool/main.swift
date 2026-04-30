import Foundation

// MARK: - CLI

/// Usage:
///   BridgeGeneratorTool \
///     --symbol-graph <path>          (repeatable)
///     [--allowlist <path>]
///     [--auto-allowlist]
///     [--blocklist <path>]
///     --output-stdlib <path>
///     --output-foundation <path>
///
/// Either `--allowlist` or `--auto-allowlist` must be supplied.
/// `--auto-allowlist` harvests every bridgeable symbol from the loaded
/// graphs (useful for "give me everything you can"); `--blocklist`
/// (paths, one per line, like the allowlist) excludes specific entries
/// from the auto-harvest, e.g. for symbols whose auto-bridge diverges
/// from a hand-rolled implementation.
struct CLI {
    var symbolGraphs: [URL] = []
    var allowlist: URL?
    var autoAllowlist: Bool = false
    var blocklist: URL?
    /// Optional set of `Type.member` symbols extracted from a cross-
    /// platform reference (swift-corelibs-foundation). When supplied,
    /// every emitted bridge entry whose owning type/member is *not* in
    /// this set gets wrapped in `#if canImport(Darwin)` so it stays out
    /// of the Linux/Windows build. Without it, every entry is treated
    /// as cross-platform — preserving the prior behavior.
    var sclSymbols: URL?
    var outputStdlib: URL?
    var outputFoundation: URL?
}

func parseArgs() -> CLI {
    var cli = CLI()
    var args = Array(CommandLine.arguments.dropFirst()).makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--symbol-graph":
            if let v = args.next() { cli.symbolGraphs.append(URL(fileURLWithPath: v)) }
        case "--allowlist":
            if let v = args.next() { cli.allowlist = URL(fileURLWithPath: v) }
        case "--auto-allowlist":
            cli.autoAllowlist = true
        case "--blocklist":
            if let v = args.next() { cli.blocklist = URL(fileURLWithPath: v) }
        case "--scl-symbols":
            if let v = args.next() { cli.sclSymbols = URL(fileURLWithPath: v) }
        case "--output-stdlib":
            if let v = args.next() { cli.outputStdlib = URL(fileURLWithPath: v) }
        case "--output-foundation":
            if let v = args.next() { cli.outputFoundation = URL(fileURLWithPath: v) }
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
            exit(2)
        }
    }
    return cli
}

let cli = parseArgs()
guard !cli.symbolGraphs.isEmpty,
      (cli.allowlist != nil || cli.autoAllowlist),
      let outputStdlibURL = cli.outputStdlib,
      let outputFoundationURL = cli.outputFoundation
else {
    FileHandle.standardError.write(Data("""
        usage: BridgeGeneratorTool \
        --symbol-graph <path> [--symbol-graph <path>...] \
        [--allowlist <path>] [--auto-allowlist] [--blocklist <path>] \
        --output-stdlib <path> \
        --output-foundation <path>

        """.utf8))
    exit(2)
}

// MARK: - Inputs

func parseList(_ url: URL, kind: String) -> Set<String> {
    do {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return Set(contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    } catch {
        FileHandle.standardError.write(Data("error reading \(kind): \(error)\n".utf8))
        exit(1)
    }
}

let allowlist: Set<String>
if let url = cli.allowlist {
    allowlist = parseList(url, kind: "allowlist")
} else {
    allowlist = []
}
let blocklist: Set<String> = cli.blocklist.map { parseList($0, kind: "blocklist") } ?? []
let autoAllowlist = cli.autoAllowlist

/// Cross-platform symbol oracle (swift-corelibs-foundation extract).
/// Each entry is either `Type.member` (cross-platform) or
/// `Type.member\tUNAVAILABLE` (declared in scl source but marked
/// `@available(*, unavailable)`, treated as Apple-only). Members
/// without a matching key are also Apple-only.
struct SCLOracle {
    /// Available cross-platform `(typeName, memberName)` pairs. Empty
    /// memberName entries (`Type.`) are type-level markers; empty
    /// typeName entries (`.funcName`) are top-level functions.
    let crossPlatform: Set<String>
    /// Types declared in scl source but with `@available(*, unavailable)`.
    /// Treated as Apple-only by the classifier even though their type
    /// marker would otherwise be present.
    let unavailableTypes: Set<String>
    /// Top-level functions declared in scl source.
    let topLevelFunctions: Set<String>

    /// `nil` means no oracle was provided — treat everything as cross-
    /// platform (legacy behavior, no `#if canImport(Darwin)` gating).
    static func load(_ url: URL?) -> SCLOracle? {
        guard let url else { return nil }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            var keep: Set<String> = []
            var unavailableTypes: Set<String> = []
            var topLevelFns: Set<String> = []
            for line in contents.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.components(separatedBy: "\t")
                let key = parts[0]
                let unavailable = parts.count >= 2 && parts[1] == "UNAVAILABLE"
                // Type-level marker: `Type.` (member name empty).
                if key.hasSuffix(".") {
                    let typeName = String(key.dropLast())
                    if unavailable { unavailableTypes.insert(typeName) }
                    else { keep.insert(key) }
                    continue
                }
                // Top-level function: `.funcName` (type name empty).
                if key.hasPrefix(".") {
                    if !unavailable { topLevelFns.insert(String(key.dropFirst())) }
                    continue
                }
                if !unavailable { keep.insert(key) }
            }
            return SCLOracle(
                crossPlatform: keep,
                unavailableTypes: unavailableTypes,
                topLevelFunctions: topLevelFns
            )
        } catch {
            FileHandle.standardError.write(Data("error reading scl symbols: \(error)\n".utf8))
            exit(1)
        }
    }

    /// True when the `Type.member` pair is in the cross-platform set.
    func isCrossPlatform(typeName: String, memberName: String) -> Bool {
        // Top-level free function: look up by name in the function set.
        if typeName.isEmpty {
            return topLevelFunctions.contains(memberName)
        }
        // Stdlib types (Int, Double, String, Bool, Array, …) — scl is
        // Foundation-only, so we whitelist them here. Nested stdlib
        // types like `String.Index` have a few Apple-only extensions
        // (e.g. `debugDescription`); blocklist those individually.
        if stdlibCrossPlatformOwners.contains(typeName) { return true }
        // Check the type-member as-is (with NS-prefixed fallback for
        // scl's NSXxx-keyed members).
        if crossPlatform.contains("\(typeName).\(memberName)") { return true }
        let nsCandidate: String
        if let dot = typeName.firstIndex(of: ".") {
            nsCandidate = "NS\(typeName[..<dot])\(typeName[dot...]).\(memberName)"
        } else {
            nsCandidate = "NS\(typeName).\(memberName)"
        }
        return crossPlatform.contains(nsCandidate)
    }

    /// True when the type itself exists on the cross-platform side
    /// (declared in scl source AND not marked unavailable). Used by
    /// the comparator emitter — emitting a comparator for a type that
    /// doesn't exist on Linux would break that build.
    func isTypeCrossPlatform(_ typeName: String) -> Bool {
        if stdlibCrossPlatformOwners.contains(typeName) { return true }
        if unavailableTypes.contains(typeName) { return false }
        if crossPlatform.contains("\(typeName).") { return true }
        // NS-prefixed fallback.
        let nsCandidate: String
        if let dot = typeName.firstIndex(of: ".") {
            nsCandidate = "NS\(typeName[..<dot])\(typeName[dot...])."
        } else {
            nsCandidate = "NS\(typeName)."
        }
        if unavailableTypes.contains(String(nsCandidate.dropLast())) { return false }
        return crossPlatform.contains(nsCandidate)
    }
}

/// Owners that exist in the standard library, not in Foundation. The
/// scl extract doesn't catalog these, so the classifier whitelists
/// them as cross-platform.
let stdlibCrossPlatformOwners: Set<String> = [
    "Int", "Double", "String", "Bool", "Array", "Dictionary", "Set",
    "Range", "ClosedRange", "Optional", "Result", "Character",
    "Substring", "String.Index", "Mirror", "ObjectIdentifier",
    "OpaquePointer", "UnsafeRawPointer", "UnsafeMutableRawPointer",
    "UnsafeCurrentTask", "TaskPriority", "UnownedTaskExecutor",
]

let sclOracle = SCLOracle.load(cli.sclSymbols)
if sclOracle != nil {
    FileHandle.standardError.write(Data(
        "scl oracle: \(sclOracle!.crossPlatform.count) cross-platform symbols loaded\n".utf8
    ))
}

/// A symbol paired with the module it was extracted from. We need the
/// module name to route the emit — stdlib bridges register at startup;
/// Foundation bridges only after `import Foundation`.
struct AnnotatedSymbol {
    let module: String
    let symbol: SymbolGraph.Symbol
}

var allSymbols: [AnnotatedSymbol] = []
/// Per-source-USR conformance set, accumulated across all graphs. Used to
/// emit comparators on bridged opaque types that conform to `Equatable`
/// or `Comparable`.
var conformancesByUSR: [String: Set<String>] = [:]
for url in cli.symbolGraphs {
    do {
        let data = try Data(contentsOf: url)
        let graph = try JSONDecoder().decode(SymbolGraph.self, from: data)
        for s in graph.symbols {
            allSymbols.append(AnnotatedSymbol(module: graph.module.name, symbol: s))
        }
        for r in graph.relationships ?? [] where r.kind == "conformsTo" {
            conformancesByUSR[r.source, default: []].insert(r.target)
        }
    } catch {
        FileHandle.standardError.write(
            Data("error reading symbol graph \(url.path): \(error)\n".utf8)
        )
        exit(1)
    }
}

let equatableUSR = "s:SQ"
let comparableUSR = "s:SL"
let optionSetUSR = "s:s9OptionSetP"

// Auto-discovery of opaque-bridgeable types runs further down, AFTER
// `bridgedTypes` and `bridgeableReceivers` are declared. (Swift top-
// level code executes in source order, so it has to live below the
// declarations.) See "Auto-discovery pass".

// MARK: - Type table

/// Map from precise identifier (USR) to our `Value`-side type. Returning
/// nil means the type isn't bridgeable today — the symbol gets skipped.
struct BridgedType {
    /// Source-Swift spelling, e.g. "Double", "Int", "String".
    let swiftSpelling: String
    /// Code that, given a `Value` named `<expr>`, produces the unboxed
    /// Swift value. Receives the expression string in the `%@` placeholder.
    let unboxTemplate: String
    /// Code that wraps a Swift `<expr>` back into a `Value`. Same `%@` rule.
    let boxTemplate: String
}

/// Helper for opaque-bridged Foundation types — they all use the same
/// boxOpaque/unboxOpaque ABI keyed by their `swiftSpelling`.
func opaqueBridge(_ swiftSpelling: String) -> BridgedType {
    return BridgedType(
        swiftSpelling: swiftSpelling,
        unboxTemplate: "try unboxOpaque(%@, as: \(swiftSpelling).self, typeName: \"\(swiftSpelling)\")",
        boxTemplate: "boxOpaque(%@, typeName: \"\(swiftSpelling)\")"
    )
}

/// Hand-coded "structural" bridges — types we model directly via a
/// dedicated `Value` case, not as opaque carriers. Always populated.
let primitiveBridges: [String: BridgedType] = [
    "s:Si": BridgedType(  // Swift.Int
        swiftSpelling: "Int",
        unboxTemplate: "try unboxInt(%@)",
        boxTemplate: ".int(%@)"
    ),
    "s:Sd": BridgedType(  // Swift.Double
        swiftSpelling: "Double",
        unboxTemplate: "try toDouble(%@)",
        boxTemplate: ".double(%@)"
    ),
    "s:SS": BridgedType(  // Swift.String
        swiftSpelling: "String",
        unboxTemplate: "try unboxString(%@)",
        boxTemplate: ".string(%@)"
    ),
    "s:Sb": BridgedType(  // Swift.Bool
        swiftSpelling: "Bool",
        unboxTemplate: "try unboxBool(%@)",
        boxTemplate: ".bool(%@)"
    ),
    // `TimeInterval` is a Foundation typealias for `Double`; it shows up
    // in symbol graphs with this Clang-flavored USR.
    "c:@T@NSTimeInterval": BridgedType(
        swiftSpelling: "Double",
        unboxTemplate: "try toDouble(%@)",
        boxTemplate: ".double(%@)"
    ),
]

/// Auto-discovered + hand-coded opaque overrides. The auto-discovery
/// pass below runs after the symbol graphs load and populates this with
/// any `swift.struct` (or class) that conforms to `Equatable`. Hand
/// overrides for typealias-shaped types (`String.Encoding` lives as a
/// nested-typealias struct).
nonisolated(unsafe) var bridgedTypes: [String: BridgedType] = primitiveBridges

/// Set of bridged type names that are reference-type Swift classes
/// (vs structs). Populated alongside `bridgedTypes` during auto-
/// discovery; consulted at property emit time to decide whether to
/// emit a setter alongside the getter for `var` properties — only
/// classes get the setter, since their underlying reference allows
/// in-place mutation through an `.opaque` Value.
nonisolated(unsafe) var bridgedClassTypeNames: Set<String> = []

/// Types we auto-promote into `bridgedTypes` regardless of whether
/// the symbol graph reports `Equatable` conformance. Two cases:
///
///   - **Reference types** we want bridged (`URLSession`, `JSONEncoder`,
///     `FileManager`, …). Most don't conform to Equatable.
///   - **OptionSet-shaped nested types** under bridged classes
///     (`JSONEncoder.OutputFormatting`, …). Their conformance comes
///     through the `OptionSet` protocol which the symbol graph encodes
///     differently from a direct Equatable conformance.
///
/// Keep this list short: each class drags in an inheritance chain whose
/// method names can shadow `NSObject` and break the bridge dispatcher.
/// When adding one, regen and watch for compile errors in the per-type
/// file before keeping the addition.
let bridgeableTypeAllowlist: Set<String> = [
    // Reference-type Foundation classes
    "URLSession",
    "URLResponse",
    "HTTPURLResponse",
    "JSONEncoder",
    "JSONDecoder",
    "PropertyListEncoder",
    "PropertyListDecoder",
    "FileManager",
    "ProcessInfo",
    // OptionSet-style nested types under bridged classes
    "JSONEncoder.OutputFormatting",
]

/// Names of types we explicitly DON'T auto-promote, even if they
/// conform to Equatable. Useful when the type is structurally modelled
/// elsewhere (e.g. we model `Array`/`Set`/`Dictionary` via dedicated
/// `Value` cases, not opaque) or when its public API is too large to
/// safely auto-bridge.
let autoPromoteSkip: Set<String> = [
    "Array", "Dictionary", "Set", "Range", "ClosedRange", "Optional",
    "Substring", "StaticString", "Character", "Unicode.Scalar",
    "AnyHashable", "AnyKeyPath",
    // Numeric stdlib types we don't bridge separately — they're
    // structurally bridged via Int/Double, and adding them as opaque
    // would cause type confusion.
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Int8", "Int16", "Int32", "Int64", "Int128", "UInt128",
    "Float", "Float80", "Float16",
    // macOS-only types that the macOS-extracted symbol graph reports
    // as universally available but the iOS Foundation overlay doesn't
    // expose. Skipping promotion keeps the package buildable on iOS.
    "AffineTransform", "AlignmentOptions",
    "NSAppleEventDescriptor.SendOptions",
    "FileManager.UnmountOptions",
    "DistributedNotificationCenter.CenterType",
    "DistributedNotificationCenter.Options",
    "XMLNode.Options",
]

/// When the symbol's owning type is one of these, we re-target the emit
/// to the value listed. `StringProtocol` extension methods declared by
/// Foundation are callable on concrete `String` values, so we register
/// them on `String` rather than the protocol name.
let receiverAliases: [String: String] = [
    "StringProtocol": "String",
]

/// A type extracted from a parameter or return slot, including whether it
/// was wrapped in `Optional<>` (which the Swift compiler renders as a
/// trailing `?` text fragment after the inner typeIdentifier).
struct ExtractedType {
    let bridge: BridgedType
    let isOptional: Bool
}

/// Pull the `typeIdentifier` fragment out of a parameter or return slot.
/// Returns nil if there isn't exactly one — i.e. the type isn't a bare
/// nominal we know how to box (generics, tuples, …).
///
/// `T?` shows up as `[typeIdentifier T, text "?"]` and gets returned with
/// `isOptional == true`.
///
/// When `selfType` is supplied, a fragment spelled `Self` (no USR — that's
/// what protocol-requirement extractions look like) substitutes to that
/// receiver's bridge. Lets methods like `Int.isMultiple(of: Self)` get
/// auto-bridged once we know the concrete owning type.
func extractType(
    from fragments: [SymbolGraph.Fragment],
    selfType: BridgedType? = nil
) -> ExtractedType? {
    // Reject array (`[T]`), dict (`[K: V]`), set (`Set<T>`), tuple,
    // generic, and existential types. These all show up as text
    // fragments wrapping a single typeIdentifier — bridging them needs
    // generator infra we don't have. The bare-nominal case has nothing
    // before the typeIdentifier except the parameter name and `: `.
    let textFrags = fragments.filter { $0.kind == "text" }
    let combinedText = textFrags.map(\.spelling).joined()
    if combinedText.contains("[") || combinedText.contains("<") ||
       combinedText.contains("(") || combinedText.contains("&") ||
       combinedText.contains("any ") || combinedText.contains("some ")
    {
        return nil
    }

    // Dotted-namespace types like `String.Encoding` produce TWO
    // typeIdentifier fragments separated by `.` text — `String` (the
    // namespace) and `Encoding` (the actual nominal). Use the LAST one
    // since it carries the leaf USR. The text-guard above rejects
    // anything more exotic, so this is safe.
    let typeFrags = fragments.filter { $0.kind == "typeIdentifier" }
    guard let frag = typeFrags.last else { return nil }

    // Optional wrapping: detect a `?` immediately after the typeIdentifier.
    // The compiler emits this as a text fragment that may start with `?`
    // and continue (`"? { "` for property getters, `"?"` on its own for
    // method returns). `??` (defaulted) doesn't appear here — that lives
    // in `Default.swift`-style sugar, not the type itself.
    var isOptional = false
    if let i = fragments.lastIndex(where: { $0.kind == "typeIdentifier" }),
       i + 1 < fragments.count,
       fragments[i + 1].kind == "text",
       fragments[i + 1].spelling.trimmingCharacters(in: .whitespaces).hasPrefix("?")
    {
        isOptional = true
    }

    let bridge: BridgedType
    if frag.spelling == "Self", let selfType {
        bridge = selfType
    } else if let usr = frag.preciseIdentifier, let b = bridgedTypes[usr] {
        bridge = b
    } else {
        return nil
    }
    return ExtractedType(bridge: bridge, isOptional: isOptional)
}

// MARK: - Filter + emit

struct ResolvedSignature {
    /// `(label, type, isOptional)` — `label == "_"` means unlabeled at the
    /// call site. Optional params arrive as `T?` and unbox via the same
    /// `try unbox…` template (we don't bridge Optional inputs today, so
    /// `isOptional` for params is a hard skip — see `resolveSignature`).
    let parameters: [(label: String, type: BridgedType)]
    /// `nil` here means Void; for non-Void use `returnIsOptional` to know
    /// if the bridge should wrap the result in `.optional(...)`.
    let returnType: BridgedType?
    let returnIsOptional: Bool
    /// When the return is a tuple of bridgeable elements (e.g.
    /// `(quotient: Self, remainder: Self)` on `Int.quotientAndRemainder`),
    /// the elements live here in declaration order. `returnType` is nil
    /// in that case — the bridge wraps the call in `.tuple([…])`.
    let returnTupleElements: [BridgedType]
}

/// Try to extract a tuple return type from a Swift signature's `returns`
/// fragment list. Returns nil for non-tuples or tuples with non-bridgeable
/// elements. Element labels are discarded — the bridged tuple value is
/// positional (`Value.tuple([…])`).
func extractTupleReturn(
    from fragments: [SymbolGraph.Fragment],
    selfType: BridgedType?
) -> [BridgedType]? {
    // Must start with `(` and end with `)` — but NOT be a closure type
    // like `(Int) -> Int`. The combined text after stripping parens
    // shouldn't contain `->`.
    guard let first = fragments.first, first.kind == "text", first.spelling.contains("("),
          let last = fragments.last, last.kind == "text", last.spelling.contains(")")
    else { return nil }
    let combined = fragments.map(\.spelling).joined()
    if combined.contains("->") { return nil }
    // Walk fragments at depth 1 (inside the outer parens). Each comma at
    // depth 1 separates a tuple element. Collect typeIdentifiers per
    // element; reject if any element doesn't have exactly one.
    var depth = 0
    var elements: [[SymbolGraph.Fragment]] = [[]]
    for f in fragments {
        if f.kind == "text" {
            for ch in f.spelling {
                switch ch {
                case "(", "<", "[":
                    depth += 1
                    if depth > 1 {
                        elements[elements.count - 1].append(SymbolGraph.Fragment(kind: "text", spelling: String(ch), preciseIdentifier: nil))
                    }
                case ")", ">", "]":
                    depth -= 1
                    if depth > 0 {
                        elements[elements.count - 1].append(SymbolGraph.Fragment(kind: "text", spelling: String(ch), preciseIdentifier: nil))
                    }
                case ",":
                    if depth == 1 {
                        elements.append([])
                    } else {
                        elements[elements.count - 1].append(SymbolGraph.Fragment(kind: "text", spelling: String(ch), preciseIdentifier: nil))
                    }
                default:
                    if depth >= 1 {
                        elements[elements.count - 1].append(SymbolGraph.Fragment(kind: "text", spelling: String(ch), preciseIdentifier: nil))
                    }
                }
            }
        } else if depth >= 1 {
            elements[elements.count - 1].append(f)
        }
    }
    guard elements.count >= 2 else { return nil }  // single-element tuples are silly
    var result: [BridgedType] = []
    for el in elements {
        guard let t = extractType(from: el, selfType: selfType) else { return nil }
        if t.isOptional { return nil }   // Optional tuple elements not bridged.
        result.append(t.bridge)
    }
    return result
}

/// Pull argument labels from a method title like `distance(to:)` →
/// `["to"]`, `isLessThanOrEqualTo(_:)` → `["_"]`, `f(_:_:)` → `["_", "_"]`.
/// Used at the call site since `name`/`internalName` in the symbol-graph
/// `parameters[]` don't reliably distinguish labelled vs unlabelled.
func argLabels(fromTitle title: String) -> [String] {
    guard let open = title.firstIndex(of: "("),
          let close = title.lastIndex(of: ")"),
          open < close
    else { return [] }
    let inside = title[title.index(after: open)..<close]
    if inside.isEmpty { return [] }
    return inside.split(separator: ":", omittingEmptySubsequences: false)
        .dropLast()
        .map(String.init)
}

func resolveSignature(_ sym: SymbolGraph.Symbol) -> ResolvedSignature? {
    guard let sig = sym.functionSignature else { return nil }
    let labels = argLabels(fromTitle: sym.names.title)
    let paramSyntaxes = sig.parameters ?? []
    guard labels.count == paramSyntaxes.count else { return nil }
    // For instance methods, the `Self` placeholder in protocol-requirement
    // signatures resolves to the owning type's bridge. Walk through the
    // alias map so `StringProtocol` resolves like `String`.
    let selfBridge: BridgedType?
    if sym.pathComponents.count == 2 {
        let owner = receiverAliases[sym.pathComponents[0]] ?? sym.pathComponents[0]
        selfBridge = bridgeableReceivers[owner]
    } else {
        selfBridge = nil
    }
    // Inout parameters can't be bridged through our value-passing
    // closures — the receiver-side `Value` is a copy.
    let inouts = parameterInouts(in: sym, count: paramSyntaxes.count)
    if inouts.contains(true) { return nil }
    // Per-parameter default-arg detection lets us drop params that have a
    // default value AND a non-bridgeable type — the Swift call site uses
    // the default. Unlocks methods like `Data(contentsOf:options:)` where
    // `options: ReadingOptions = []` is the only blocker.
    let defaults = parameterDefaults(in: sym, count: paramSyntaxes.count)
    var params: [(String, BridgedType)] = []
    for (i, (label, p)) in zip(labels, paramSyntaxes).enumerated() {
        if let t = extractType(from: p.declarationFragments, selfType: selfBridge) {
            if t.isOptional { return nil }  // Optional inputs not bridged.
            params.append((label, t.bridge))
            continue
        }
        // Unbridgeable type — only acceptable if the param has a default
        // we can rely on at the Swift call site.
        if i < defaults.count, defaults[i] {
            // Drop the param from our bridge — Swift fills in the default.
            continue
        }
        return nil
    }
    var ret: BridgedType? = nil
    var retOptional = false
    var retTupleElements: [BridgedType] = []
    if let returns = sig.returns {
        // Swift returns are a single fragment list. Void shows up as no
        // typeIdentifier fragments at all (or `Void` USR).
        let typeFrags = returns.filter { $0.kind == "typeIdentifier" }
        if !typeFrags.isEmpty {
            // Try a single-typed return first; if extractType rejects it
            // because of the `(` text guard (a tuple), fall back to
            // tuple-element extraction.
            if let t = extractType(from: returns, selfType: selfBridge) {
                ret = t.bridge
                retOptional = t.isOptional
            } else if let elements = extractTupleReturn(from: returns, selfType: selfBridge) {
                retTupleElements = elements
            } else {
                return nil
            }
        } else {
            // No `typeIdentifier` — could be true Void, or an
            // unbridgeable spelling like `Any`/`Never`/`some P` that
            // shows up only as keyword/text fragments. Treat anything
            // with non-empty content other than `Void`/`()` as a
            // bridge-blocker so we don't silently discard the return.
            let spelling = returns.map(\.spelling).joined()
                .trimmingCharacters(in: .whitespaces)
            if !spelling.isEmpty && spelling != "Void" && spelling != "()" {
                return nil
            }
        }
    }
    return ResolvedSignature(
        parameters: params,
        returnType: ret,
        returnIsOptional: retOptional,
        returnTupleElements: retTupleElements
    )
}

/// Render a unbox/box step using the BridgedType's template.
func render(_ template: String, _ expr: String) -> String {
    return template.replacingOccurrences(of: "%@", with: expr)
}

// MARK: - Unified closure-emit helper
//
// The five callable kinds (`swift.func`, `swift.method`, `swift.init`,
// `swift.property`, `swift.type.method`) share the shape:
//   `i.register…(<key>) { <closureParams> in
//       <arity guard>
//       <receiver unbox?>
//       <return expr>
//   }`
// Differences are confined to: which `register` overload, what the
// closure parameters are, whether we unbox a receiver, what the
// callExpr looks like, and what label we use in arity error messages.
// Capture those in `EmitConfig`; the emit is then mechanical.

struct EmitConfig {
    /// Lead-in for a dict entry — `"<key>": .<case>`. The renderer
    /// appends ` { <closureParams> in <body> },` for the closure-bearing
    /// cases. Static-value entries don't go through `renderEmit`; they
    /// are emitted directly as a one-line dict entry.
    let registerLine: String
    /// The closure's parameter list — `args`, `receiver, args`, or `receiver`.
    let closureParams: String
    /// Whether to emit an `args.count == N` guard. `nil` means no guard
    /// (zero-arg closures like `registerComputed`'s `receiver in` form).
    let arity: Int?
    /// Receiver unbox line (`let recv: T = try unboxT(receiver)`), or nil.
    let recvUnboxLine: String?
    /// The body's call expression, e.g. `recv.foo(<args>)`, `URL(<args>)`,
    /// `Foo.staticMethod(<args>)`. Already includes unboxed args.
    let callExpr: String
    /// Used in the arity-fail diagnostic, e.g. `"URL.absoluteString"` or
    /// `"URL(string:)"`.
    let errorPrefix: String
    /// Return shape — flat-value, optional, throwing, tuple combinations.
    let returnType: BridgedType?
    let isOptional: Bool
    let isThrowing: Bool
    let isAsync: Bool
    let tupleElements: [BridgedType]
}

/// Render a runtime-time call: `i.<registerLine> { <params> in <body> }`.
/// Used for globals (`registerGlobal(name:)`) which don't fit the
/// bridges table — they bind into root scope at install time.
func renderRuntimeEmit(_ c: EmitConfig) -> String {
    let returnExpr = buildReturnExpr(
        callExpr: c.callExpr,
        returnType: c.returnType,
        isOptional: c.isOptional,
        isThrowing: c.isThrowing,
        isAsync: c.isAsync,
        tupleElements: c.tupleElements
    )
    var bodyLines: [String] = []
    if let arity = c.arity {
        bodyLines.append("            guard args.count == \(arity) else {")
        bodyLines.append("                throw RuntimeError.invalid(\"\(c.errorPrefix): expected \(arity) argument(s), got \\(args.count)\")")
        bodyLines.append("            }")
    }
    if let recv = c.recvUnboxLine {
        bodyLines.append("            \(recv)")
    }
    bodyLines.append("            \(returnExpr)")
    return """
            \(c.registerLine) { \(c.closureParams) in
    \(bodyLines.joined(separator: "\n"))
            }
    """
}

/// Render a dict entry: `"key": .case { params in body },`. Each per-
/// type generated file is a `static let <type>: [String: Bridge] = [
/// <entries> ]`, so emits all share this dict-entry shape.
func renderEmit(_ c: EmitConfig) -> String {
    let returnExpr = buildReturnExpr(
        callExpr: c.callExpr,
        returnType: c.returnType,
        isOptional: c.isOptional,
        isThrowing: c.isThrowing,
        isAsync: c.isAsync,
        tupleElements: c.tupleElements
    )
    var bodyLines: [String] = []
    if let arity = c.arity {
        bodyLines.append("        guard args.count == \(arity) else {")
        bodyLines.append("            throw RuntimeError.invalid(\"\(c.errorPrefix): expected \(arity) argument(s), got \\(args.count)\")")
        bodyLines.append("        }")
    }
    if let recv = c.recvUnboxLine {
        bodyLines.append("        \(recv)")
    }
    bodyLines.append("        \(returnExpr)")
    return """
        \(c.registerLine) { \(c.closureParams) in
    \(bodyLines.joined(separator: "\n"))
        },
    """
}

/// Common arg-unboxing: produces the Swift-source argument list
/// `(label: try unboxX(args[0]), …)` that goes inside the wrapped call.
func unboxedCallArgs(for sig: ResolvedSignature) -> String {
    let unboxed = sig.parameters.enumerated().map { (i, p) in
        render(p.type.unboxTemplate, "args[\(i)]")
    }
    return zip(sig.parameters, unboxed)
        .map { (p, u) in (p.label == "_" ? "" : "\(p.label): ") + u }
        .joined(separator: ", ")
}

/// True when a method's `declarationFragments` start with `mutating` —
/// the bridge ABI passes the receiver by value, so there's no path to
/// mutate it from the closure body. Mutating methods stay hand-rolled
/// via `tryMutatingMethodCall` in the interpreter.
func isMutating(_ sym: SymbolGraph.Symbol) -> Bool {
    let fragments = sym.declarationFragments ?? []
    return fragments.first?.spelling == "mutating"
}

/// True for `swift.property` symbols declared with `var` and not
/// marked `{ get }`-only. Used to decide whether to emit a setter
/// alongside the getter for class-typed receivers.
func isVarMutable(_ sym: SymbolGraph.Symbol) -> Bool {
    let frags = sym.declarationFragments ?? []
    var sawVar = false
    var hasGet = false
    var hasSet = false
    for f in frags {
        if f.kind == "keyword" {
            switch f.spelling {
            case "var": sawVar = true
            case "let": return false
            case "get": hasGet = true
            case "set": hasSet = true
            default: break
            }
        }
    }
    guard sawVar else { return false }
    // `var foo: T { get }` — read-only computed (get with no set).
    if hasGet && !hasSet { return false }
    return true
}

/// True for `@available(*, deprecated)`, `unavailable`, or symbols
/// introduced after our deployment target. The deployment target lives
/// in `Package.swift` (macOS 26 today); we bake it in here to keep the
/// generator self-contained.
let deploymentMacOSMajor = 26
let deploymentMacOSMinor = 0

func isDeprecated(_ sym: SymbolGraph.Symbol) -> Bool {
    guard let avail = sym.availability else { return false }
    for a in avail {
        if a.isUnconditionallyDeprecated == true { return true }
        if a.isUnconditionallyUnavailable == true { return true }
        if a.obsoleted != nil { return true }
        // "Soft-deprecated" symbols carry `deprecated: { major: 100000 }` —
        // a sentinel meaning "we'd like you to migrate, but the symbol
        // still compiles and runs". Only treat as deprecated if the
        // version is below the sentinel. macOS-domain entries also gate
        // on the deployment target so a future-macOS deprecation
        // doesn't pre-emptively trip when building for an older OS.
        if let dep = a.deprecated?.major {
            let softSentinel = 100000
            if dep < softSentinel {
                if a.domain == "macOS" {
                    if dep <= deploymentMacOSMajor { return true }
                } else {
                    // `swift`, `*`, and per-platform domains other than
                    // macOS — if the version says deprecated, swiftc
                    // emits the warning, so skip the bridge.
                    return true
                }
            }
        }
        if a.domain == "macOS",
           let major = a.introduced?.major
        {
            if major > deploymentMacOSMajor { return true }
            if major == deploymentMacOSMajor,
               let minor = a.introduced?.minor,
               minor > deploymentMacOSMinor
            {
                return true
            }
        }
    }
    return false
}

/// True if the method signature includes `throws`.
func isThrowing(_ sym: SymbolGraph.Symbol) -> Bool {
    let fragments = sym.declarationFragments ?? []
    return fragments.contains { $0.kind == "keyword" && $0.spelling == "throws" }
}

/// Single parsed parameter from a method's declarationFragments —
/// label spelling (`"_"` or `"from"`) plus the declared type spelling
/// (`"T"`, `"T.Type"`, `"Data"`).
struct GenericFragmentParam {
    let labelClause: String   // "_" / "from"
    let type: String          // "T" / "T.Type" / "Data"
}

struct GenericFragmentParse {
    let params: [GenericFragmentParam]
    let returnType: String
}

/// Hand-walk the symbol's declarationFragments to pull out the
/// labelled parameter list and return type. Used by the generic-method
/// pass when `resolveSignature` rejects T-typed slots.
///
/// The parser is character-aware inside `text` fragments because
/// SwiftDocC bundles `.Type, ` and `) ` style separators into a single
/// `text` fragment alongside grammar punctuation; we have to split
/// them carefully.
func parseGenericMethodFragments(_ frags: [SymbolGraph.Fragment]) -> GenericFragmentParse? {
    // Find the `(` that opens the parameter list. SwiftDocC sometimes
    // emits this fragment as `>(` (the close of the generic clause +
    // the open paren); treat any `(` inside a text fragment as the
    // start.
    var i = 0
    while i < frags.count {
        if frags[i].kind == "text", frags[i].spelling.contains("(") { i += 1; break }
        i += 1
    }
    guard i <= frags.count else { return nil }

    var params: [GenericFragmentParam] = []
    var label = ""
    var typeText = ""
    var inType = false
    var done = false

    while i < frags.count, !done {
        let f = frags[i]
        switch f.kind {
        case "externalParam":
            label = f.spelling
        case "internalParam":
            break
        case "text":
            for ch in f.spelling {
                if !inType {
                    if ch == ":" { inType = true; continue }
                    // skip leading whitespace before type
                } else {
                    if ch == "," {
                        params.append(GenericFragmentParam(
                            labelClause: label.isEmpty ? "_" : label,
                            type: typeText.trimmingCharacters(in: .whitespaces)
                        ))
                        label = ""; typeText = ""; inType = false
                    } else if ch == ")" {
                        params.append(GenericFragmentParam(
                            labelClause: label.isEmpty ? "_" : label,
                            type: typeText.trimmingCharacters(in: .whitespaces)
                        ))
                        done = true
                        break
                    } else {
                        typeText.append(ch)
                    }
                }
            }
        default:
            if inType { typeText += f.spelling }
        }
        i += 1
    }

    // After `)`: find `-> ReturnType`, skipping `throws`/`async`
    // keywords and stopping before any `where` clause.
    var returnType = "Void"
    while i < frags.count {
        let f = frags[i]
        if f.kind == "text", f.spelling.contains("->") {
            i += 1
            var rt = ""
            while i < frags.count {
                let g = frags[i]
                if g.kind == "keyword", g.spelling == "where" { break }
                rt += g.spelling
                i += 1
            }
            returnType = rt.trimmingCharacters(in: .whitespaces)
            break
        }
        i += 1
    }
    return GenericFragmentParse(params: params, returnType: returnType)
}

/// True if the method has unbound generic parameters or a `where`
/// clause — we can't bridge these because the call site can't pick
/// concrete witnesses. Detected via the `swiftGenerics` field (most
/// reliable) plus a fragment scan as a backstop.
func isGeneric(_ sym: SymbolGraph.Symbol) -> Bool {
    if let params = sym.swiftGenerics?.parameters, !params.isEmpty { return true }
    let fragments = sym.declarationFragments ?? []
    for f in fragments {
        if f.kind == "keyword" && f.spelling == "where" { return true }
    }
    var seenOpen = false
    for f in fragments {
        if f.kind == "text" {
            for ch in f.spelling {
                if ch == "(" { seenOpen = true; break }
                if ch == "<" && !seenOpen { return true }
            }
            if seenOpen { break }
        }
    }
    return false
}

/// True if the method or property is `async`. Bridge closures aren't
/// async-capable today.
func isAsync(_ sym: SymbolGraph.Symbol) -> Bool {
    let fragments = sym.declarationFragments ?? []
    return fragments.contains { $0.kind == "keyword" && $0.spelling == "async" }
}

/// Per-parameter "is `inout`" flags. We can't bridge inout (the
/// closure's args arrive by value), so any symbol with an inout param
/// is unbridgeable. Detected via the `inout` keyword fragment appearing
/// at depth 1 between this param's start and the next.
func parameterInouts(in sym: SymbolGraph.Symbol, count: Int) -> [Bool] {
    let fragments = sym.declarationFragments ?? []
    guard count > 0 else { return [] }
    var result = [Bool](repeating: false, count: count)
    var paramIdx = -1
    var depth = 0
    for f in fragments {
        if f.kind == "text" {
            for ch in f.spelling {
                switch ch {
                case "(", "<", "[":
                    depth += 1
                    if depth == 1 { paramIdx = 0 }
                case ")", ">", "]":
                    depth -= 1
                case ",":
                    if depth == 1 { paramIdx += 1 }
                default: break
                }
            }
        } else if f.kind == "keyword", f.spelling == "inout",
                  depth == 1, paramIdx >= 0, paramIdx < count
        {
            result[paramIdx] = true
        }
    }
    return result
}

/// Per-parameter "has a default value" flags in declaration order.
///
/// Walk the symbol's full declarationFragments at depth 1 (inside the
/// outer `(...)`), tracking which parameter we're in by counting commas.
/// A parameter with `=` somewhere in its text fragments has a default.
/// Generic-bracket commas (`Dictionary<K, V>`) are skipped via depth
/// tracking on `<>` and `()`.
func parameterDefaults(in sym: SymbolGraph.Symbol, count: Int) -> [Bool] {
    let fragments = sym.declarationFragments ?? []
    guard count > 0 else { return [] }
    var result = [Bool](repeating: false, count: count)
    var paramIdx = -1   // -1 = before first `(`
    var depth = 0       // bracket nesting; 1 means "inside outer parens"
    for f in fragments {
        if f.kind == "text" {
            for ch in f.spelling {
                switch ch {
                case "(", "<", "[":
                    depth += 1
                    if depth == 1 { paramIdx = 0 }
                case ")", ">", "]":
                    depth -= 1
                case ",":
                    if depth == 1 {
                        paramIdx += 1
                    }
                case "=":
                    // Only count when at depth 1 (top-level param defs).
                    // Type-level `=` like `where T == U` is at depth 0
                    // so won't trigger.
                    if depth == 1, paramIdx >= 0, paramIdx < count {
                        result[paramIdx] = true
                    }
                default: break
                }
            }
        }
    }
    return result
}

/// Build the `return …` statement(s) for a method/init/global call.
///
/// - When the signature throws (`throws` keyword), wrap in `do/catch`
///   that re-raises Swift errors as `UserThrowSignal` so script-side
///   `do/catch` blocks can handle them.
/// - When the return is Optional, emit a guard-let so the success case
///   wraps in `.optional(…)` and the nil case becomes `.optional(nil)`.
/// - When throwing AND optional, both transforms apply.
/// - Plain Void returns emit a bare expression statement (no `_ =`,
///   which the compiler flags as redundant for `Void`-returning calls).
func buildReturnExpr(
    callExpr: String,
    returnType: BridgedType?,
    isOptional: Bool,
    isThrowing: Bool = false,
    isAsync: Bool = false,
    tupleElements: [BridgedType] = []
) -> String {
    let prefix = (isThrowing ? "try " : "") + (isAsync ? "await " : "")

    func core() -> String {
        if !tupleElements.isEmpty {
            // Tuple return: bind the call result to a temporary, then box
            // each positional element via its element-type's box template.
            let parts = tupleElements.enumerated().map { (i, bridge) in
                render(bridge.boxTemplate, "_t.\(i)")
            }
            return """
            let _t = \(prefix)\(callExpr)
                    return .tuple([\(parts.joined(separator: ", "))])
            """
        }
        guard let ret = returnType else {
            return "\(prefix)\(callExpr)\n            return .void"
        }
        if isOptional {
            return """
            if let _v = \(prefix)\(callExpr) {
                        return .optional(\(render(ret.boxTemplate, "_v")))
                    }
                    return .optional(nil)
            """
        }
        return "return " + render(ret.boxTemplate, "\(prefix)\(callExpr)")
    }

    if isThrowing {
        return """
        do {
                    \(core())
                } catch {
                    throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
                }
        """
    }
    return core()
}

// Walk symbols, pick out matches. Each emit goes into one of two groups
// based on the source module: `Swift` symbols register at interpreter
// startup; `Foundation` (and friends) wait for `import Foundation`.
enum EmitGroup { case stdlib, foundation }
/// What kind of file an emit lands in:
/// - `.type(name)`: per-type bridge dict (`static let url: [String: Bridge] = [...]`)
/// - `.runtime`:    code that runs at install time (globals, comparators)
enum EmitBucket {
    case type(String)
    case runtime
}
/// Whether the emit needs `#if canImport(Darwin)` gating.
enum Platform {
    case crossPlatform
    case appleOnly
}

struct EmitEntry {
    let symbolPath: String   // "sqrt(_:)" or "String.foo(...)"
    let group: EmitGroup
    let bucket: EmitBucket
    let code: String
    let platform: Platform
}

/// Parse a bridge entry's display key (e.g. `"var URL.path: String"` or
/// `"init URL(_:)"` or `"static func URL.allocate()"`) into a
/// `(typeName, memberName)` pair. Returns nil for free-function entries
/// that have no owning type. Used to look the entry up in the scl
/// oracle for cross-platform classification.
func ownerAndMember(forBridgeKey key: String) -> (String, String)? {
    // Normalize `"static let X.foo"` and similar prefixes — the trailing
    // tokens are what matter.
    var s = key
    for prefix in ["static let ", "static var ", "static func ",
                   "let ", "var ", "func ", "init "] {
        if s.hasPrefix(prefix) { s.removeFirst(prefix.count); break }
    }
    // For `init URL(_:)` form: the type name precedes the `(`.
    if let openParen = s.firstIndex(of: "("), key.hasPrefix("init ") {
        return (String(s[..<openParen]), "init")
    }
    // Strip trailing `: ReturnType` and trailing `()` argument lists.
    if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
    if let openParen = s.firstIndex(of: "(") { s = String(s[..<openParen]) }
    s = s.trimmingCharacters(in: .whitespaces)
    // Split on the LAST `.` so nested types like `String.Index.foo`
    // resolve owner=`String.Index`, member=`foo`.
    guard let lastDot = s.lastIndex(of: ".") else { return nil }
    let owner = String(s[..<lastDot])
    let member = String(s[s.index(after: lastDot)...])
    return (owner, member)
}

/// Pull the first double-quoted string out of an emitted code chunk.
/// Per-type bridge entries always start with `    "<bridge key>":`,
/// so the first quoted run is the user-facing bridge key.
func extractBridgeKey(fromCode code: String) -> String? {
    guard let openQuote = code.firstIndex(of: "\"") else { return nil }
    var idx = code.index(after: openQuote)
    while idx < code.endIndex {
        let ch = code[idx]
        if ch == "\\" {
            idx = code.index(after: idx)
            if idx < code.endIndex { idx = code.index(after: idx) }
            continue
        }
        if ch == "\"" {
            return String(code[code.index(after: openQuote)..<idx])
        }
        idx = code.index(after: idx)
    }
    return nil
}

/// Classify a bridge key against the scl oracle. Without an oracle,
/// every entry is cross-platform (legacy behavior).
func platform(forBridgeKey key: String) -> Platform {
    guard let oracle = sclOracle else { return .crossPlatform }
    guard let (owner, member) = ownerAndMember(forBridgeKey: key) else {
        return .crossPlatform
    }
    return oracle.isCrossPlatform(typeName: owner, memberName: member)
        ? .crossPlatform : .appleOnly
}

var emitted: [EmitEntry] = []
var seenPaths: Set<String> = []
var skippedReasons: [String: String] = [:]  // path -> reason, for diagnostics

/// Decide which generated-bridges file a symbol belongs in.
///
/// `Int.max` should always be available — it's stdlib — even if the
/// authoritative symbol came from a Foundation cross-module graph. The
/// determining factor is the owning type's USR, not the source module:
///   - Stdlib primitives (`s:Si`, `s:Sd`, `s:SS`, `s:Sb` etc.) →
///     `.stdlib`. Always loaded.
///   - Anything else (Foundation opaque types, free functions surfaced
///     by Foundation, …) → `.foundation`. Loads on `import Foundation`.
/// Stdlib types whose methods/properties stay in the always-loaded
/// bridge file. Anything else routes to the Foundation file (loads on
/// `import Foundation`). The set is small and stable, so we list it.
let stdlibReceivers: Set<String> = ["Int", "Double", "String", "Bool"]

func emitGroupFor(symbol sym: SymbolGraph.Symbol, module: String) -> EmitGroup {
    // Type-owned symbols: route by the receiver type. Receiver aliases
    // (StringProtocol → String) are applied first so `StringProtocol.foo`
    // lands on the same side as `String.foo`.
    if sym.pathComponents.count == 2 {
        let raw = sym.pathComponents[0]
        let resolved = receiverAliases[raw] ?? raw
        return stdlibReceivers.contains(resolved) ? .stdlib : .foundation
    }
    // Free functions and unbridged owners: source module decides.
    return module == "Swift" ? .stdlib : .foundation
}

/// Bridgeable receiver types for method emission. Populated lazily
/// from `bridgedTypes` (post auto-discovery) — there's only one
/// authoritative table now.
nonisolated(unsafe) var bridgeableReceivers: [String: BridgedType] = [:]

// MARK: - Auto-discovery pass
//
// Walk every `swift.struct` / `swift.class` symbol seen in the loaded
// graphs and promote it to an opaque-bridged type if it:
//   - has a single-component path (top-level type)
//   - conforms to `Equatable` (so script-side `==` works)
//   - isn't in `autoPromoteSkip` (structurally modelled elsewhere)
//   - isn't already in `primitiveBridges`
// This subsumes what used to be a hand-curated 10-entry table.
for annotated in allSymbols {
    let sym = annotated.symbol
    let kind = sym.kind.identifier
    // Stick to value types — auto-promoting reference-type classes
    // pulls in the entire NSObject hierarchy, where method names collide
    // with `NSObject` itself (e.g. ambiguous `superclass`). Specific
    // Foundation classes that we WANT to bridge are listed by name in
    // `bridgeableTypeAllowlist`.
    let typeName0 = sym.pathComponents.joined(separator: ".")
    if kind == "swift.class" {
        guard bridgeableTypeAllowlist.contains(typeName0) else { continue }
    } else if kind != "swift.struct" {
        continue
    }
    // Top-level (`URL`) and one-level-nested (`String.Encoding`) are
    // both fine. We use the dotted name as the spelling so the bridge
    // emits `String.Encoding` consistently.
    guard (1...2).contains(sym.pathComponents.count) else { continue }
    let typeName = sym.pathComponents.joined(separator: ".")
    guard !autoPromoteSkip.contains(typeName) else { continue }
    // Skip types whose declaration itself is deprecated/obsoleted/post-
    // deployment-target — bridging them would force the generated code
    // to reference a deprecated symbol and emit warnings.
    guard !isDeprecated(sym) else { continue }
    let usr = sym.identifier.precise
    guard primitiveBridges[usr] == nil else { continue }
    if bridgedTypes[usr] != nil { continue }
    // Generic types (`FloatingPointFormatStyle<Value>`) can't be carried
    // as opaque without the witness — Swift refuses to infer it.
    if let params = sym.swiftGenerics?.parameters, !params.isEmpty { continue }
    let conformances = conformancesByUSR[usr] ?? []
    // Allowlisted types skip the Equatable requirement (reference-type
    // Foundation classes typically don't conform; OptionSet-style
    // nested structs route their Equatable conformance through
    // OptionSet which the symbol graph encodes differently). Structs
    // not on the list still need direct Equatable so we don't bridge
    // every value-type in the SDK.
    let isAllowed = bridgeableTypeAllowlist.contains(typeName)
    guard isAllowed || conformances.contains(equatableUSR) else { continue }
    bridgedTypes[usr] = opaqueBridge(typeName)
    if kind == "swift.class" {
        bridgedClassTypeNames.insert(typeName)
    }
}

// Build `bridgeableReceivers` from the resolved `bridgedTypes`. Two
// USRs can map to the same spelling (TimeInterval/Double); the
// stdlib-USR entry wins so methods on Double get the primitive bridge.
for (usr, bridge) in bridgedTypes {
    if let existing = bridgeableReceivers[bridge.swiftSpelling] {
        if usr.hasPrefix("s:S") && !existing.unboxTemplate.contains("toDouble") {
            continue
        }
    }
    bridgeableReceivers[bridge.swiftSpelling] = bridge
}

/// Tracks `(receiver, member)` registrations across emit so we can flag
/// overloads where two source methods would generate the same registry
/// key. We can't dispatch overloads from a single closure, so the second
/// occurrence is dropped with a warning — letting hand-written code own
/// the dispatch.
var registeredKeys: Set<String> = []

// Sort symbols for deterministic, helpful overload resolution:
//   1. Foundation source-module BEFORE Swift stdlib. Foundation overlays
//      often refine stdlib behavior (locale-aware string ops, etc.) and
//      we want those overlays to win when both expose the same path.
//      Group routing (`.stdlib` vs `.foundation`) is decided per-symbol
//      based on the OWNING TYPE — so `Int.max` still ends up in
//      `.stdlib` even if the chosen symbol came from a Foundation
//      cross-module graph.
//   2. Within a module, fewer parameters first. When two methods share
//      a name (e.g. `appendingPathComponent(_:)` vs
//      `appendingPathComponent(_:isDirectory:)`), the simpler shape wins
//      — that's almost always what the script-side user wants.
func paramCount(_ a: AnnotatedSymbol) -> Int {
    return a.symbol.functionSignature?.parameters?.count ?? 0
}
let prioritizedSymbols = allSymbols.sorted { lhs, rhs in
    let lp = lhs.module == "Foundation" ? 0 : 1
    let rp = rhs.module == "Foundation" ? 0 : 1
    if lp != rp { return lp < rp }
    return paramCount(lhs) < paramCount(rhs)
}

for annotated in prioritizedSymbols {
    let sym = annotated.symbol
    let path = sym.pathComponents.joined(separator: ".")
    if blocklist.contains(path) { continue }
    if !autoAllowlist {
        guard allowlist.contains(path) else { continue }
    } else if !allowlist.isEmpty, !allowlist.contains(path) {
        // Both flags supplied: allowlist constrains the auto-harvest.
        // (No-op when allowlist is empty, which is the typical pure-auto
        // case.)
        continue
    }
    let emitGroup = emitGroupFor(symbol: sym, module: annotated.module)
    // We *don't* dedupe by `path` here — `swift.type.property` and
    // `swift.property` can share a name (e.g. `Int.bitWidth`, accessible
    // on both the type and an instance), and we want both bridges
    // emitted. The per-kind `registeredKeys` set still blocks legitimate
    // overload clashes within a single kind.

    /// Helper: dedup a per-kind key against `registeredKeys`. Returns true
    /// if the key was claimed (continue with emit) or false if a previous
    /// symbol already won the slot.
    func claim(_ key: String, clashLabel: String) -> Bool {
        if registeredKeys.contains(key) {
            skippedReasons[path] = "overload clash with another '\(clashLabel)'"
            return false
        }
        return true
    }
    /// Helper: append an emit entry and mark all the bookkeeping in one
    /// step so the per-kind blocks below stay tight.
    func record(_ key: String, bucket: EmitBucket, code: String) {
        // The internal `key` is a claim key (used for dedup, not always
        // the same as the dict-literal key). Extract the actual bridge
        // key from the emitted code so the classifier sees the user-
        // facing form (`"var URL.path: String"`, etc.).
        let bridgeKey = extractBridgeKey(fromCode: code) ?? key
        emitted.append(EmitEntry(
            symbolPath: path, group: emitGroup, bucket: bucket, code: code,
            platform: platform(forBridgeKey: bridgeKey)
        ))
        seenPaths.insert(path)
        registeredKeys.insert(key)
    }

    switch sym.kind.identifier {
    case "swift.func" where sym.pathComponents.count == 1 && !isDeprecated(sym) && !isGeneric(sym) && !isAsync(sym):
        guard let sig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value signature"; continue
        }
        let name = sym.names.title.split(separator: "(").first.map(String.init) ?? sym.names.title
        let key = "global:\(name)"
        if !claim(key, clashLabel: name) { continue }
        // Globals don't fit the bridges table; they bind into rootScope.
        // Stay as runtime-time `i.registerGlobal(...)` calls in the
        // manifest's runtime block.
        record(key, bucket: .runtime, code: renderRuntimeEmit(EmitConfig(
            registerLine: "i.registerGlobal(name: \"\(name)\")",
            closureParams: "args",
            arity: sig.parameters.count,
            recvUnboxLine: nil,
            callExpr: "\(name)(\(unboxedCallArgs(for: sig)))",
            errorPrefix: name,
            returnType: sig.returnType,
            isOptional: sig.returnIsOptional,
            isThrowing: isThrowing(sym),
            isAsync: isAsync(sym),
            tupleElements: sig.returnTupleElements
        )))

    case "swift.method" where (2...3).contains(sym.pathComponents.count) &&
                              !isMutating(sym) &&
                              !isDeprecated(sym) &&
                              !isGeneric(sym):
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard let recvType = bridgeableReceivers[receiverTypeName] else {
            skippedReasons[path] = "unbridged receiver '\(rawReceiver)'"; continue
        }
        guard let sig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value parameter or return"; continue
        }
        let methodName = sym.names.title.split(separator: "(").first.map(String.init) ?? sym.names.title
        let key = "method:\(receiverTypeName).\(methodName)"
        if !claim(key, clashLabel: "\(receiverTypeName).\(methodName)") { continue }
        let recvUnbox = render(recvType.unboxTemplate, "receiver")
        record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
            registerLine: "\"func \(receiverTypeName).\(methodName)()\": .method",
            closureParams: "receiver, args",
            arity: sig.parameters.count,
            recvUnboxLine: "let recv: \(recvType.swiftSpelling) = \(recvUnbox)",
            callExpr: "recv.\(methodName)(\(unboxedCallArgs(for: sig)))",
            errorPrefix: "\(receiverTypeName).\(methodName)",
            returnType: sig.returnType,
            isOptional: sig.returnIsOptional,
            isThrowing: isThrowing(sym),
            isAsync: isAsync(sym),
            tupleElements: sig.returnTupleElements
        )))

    case "swift.init" where (2...3).contains(sym.pathComponents.count) && !isDeprecated(sym) && !isGeneric(sym) && !isAsync(sym):
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard let recvType = bridgeableReceivers[receiverTypeName] else {
            skippedReasons[path] = "unbridged init owner '\(rawReceiver)'"; continue
        }
        guard let sig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value parameter or return"; continue
        }
        let labels = sig.parameters.map(\.label)
        let labelKey = labels.joined(separator: ":")
        let key = "init:\(receiverTypeName)(\(labelKey))"
        if !claim(key, clashLabel: "\(receiverTypeName)(\(labelKey))") { continue }
        // `init?(…)` failability: in the fragment list, the `init`
        // keyword is followed by `?(…)` for failable variants.
        let df = sym.declarationFragments ?? []
        var failable = false
        for (i, frag) in df.enumerated() where frag.spelling == "init" {
            if i + 1 < df.count, df[i + 1].spelling.hasPrefix("?") { failable = true }
            break
        }
        let labelDoc = labels.isEmpty ? "" : labels.map { "\($0):" }.joined()
        let initKey = "init \(receiverTypeName)(\(labelDoc))"
        record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
            registerLine: "\"\(initKey)\": .`init`",
            closureParams: "args",
            arity: sig.parameters.count,
            recvUnboxLine: nil,
            callExpr: "\(receiverTypeName)(\(unboxedCallArgs(for: sig)))",
            errorPrefix: initKey,
            returnType: recvType,
            isOptional: failable,
            isThrowing: isThrowing(sym),
            isAsync: isAsync(sym),
            tupleElements: []
        )))

    case "swift.property" where (2...3).contains(sym.pathComponents.count) && !isDeprecated(sym) && !isAsync(sym):
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard let recvType = bridgeableReceivers[receiverTypeName] else {
            skippedReasons[path] = "unbridged owning type '\(rawReceiver)'"; continue
        }
        let memberName = sym.pathComponents.last!
        let key = "computed:\(receiverTypeName).\(memberName)"
        if !claim(key, clashLabel: "\(receiverTypeName).\(memberName)") { continue }
        guard let propType = extractType(
            from: sym.declarationFragments ?? [],
            selfType: recvType
        ) else {
            skippedReasons[path] = "non-value property type"; continue
        }
        let recvUnbox = render(recvType.unboxTemplate, "receiver")
        // Property keys carry the return-type spelling so the runtime
        // can resolve implicit-member expressions in property
        // assignment RHS (`.prettyPrinted` against the property's
        // declared `JSONEncoder.OutputFormatting`).
        let propTypeSpelling = propType.bridge.swiftSpelling + (propType.isOptional ? "?" : "")
        record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
            registerLine: "\"var \(receiverTypeName).\(memberName): \(propTypeSpelling)\": .computed",
            closureParams: "receiver",
            arity: nil,
            recvUnboxLine: "let recv: \(recvType.swiftSpelling) = \(recvUnbox)",
            callExpr: "recv.\(memberName)",
            errorPrefix: "\(receiverTypeName).\(memberName)",
            returnType: propType.bridge,
            isOptional: propType.isOptional,
            isThrowing: false,
            isAsync: false,
            tupleElements: []
        )))
        // For `var` properties on bridged classes, emit a setter
        // alongside the getter. The reference can be mutated in place
        // — the runtime's `setThroughChain` looks up
        // `bridges["set var Type.member: ...."]` and calls the setter
        // body. Skipped for structs (we'd need writeback through the
        // opaque Value, not modeled), for read-only computed
        // properties, and for non-bridgeable property types.
        if bridgedClassTypeNames.contains(receiverTypeName),
           !propType.isOptional,
           isVarMutable(sym)
        {
            let unboxNew = render(propType.bridge.unboxTemplate, "newValue")
            let setterCode = """
                    \"set var \(receiverTypeName).\(memberName): \(propTypeSpelling)\": .setter { receiver, newValue in
                        let recv: \(recvType.swiftSpelling) = \(recvUnbox)
                        recv.\(memberName) = \(unboxNew)
                    },
            """
            let setterClaim = "setter:\(receiverTypeName).\(memberName)"
            if !registeredKeys.contains(setterClaim) {
                emitted.append(EmitEntry(
                    symbolPath: path, group: emitGroup,
                    bucket: .type(receiverTypeName), code: setterCode,
                    platform: platform(forBridgeKey: "var \(receiverTypeName).\(memberName)")
                ))
                registeredKeys.insert(setterClaim)
            }
        }

    case "swift.type.property" where (2...3).contains(sym.pathComponents.count) && !isDeprecated(sym) && !isAsync(sym):
        // The odd one out: emits a `registerStaticValue(value: …)` call
        // (no closure body), so it bypasses `renderEmit`.
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard let recvType = bridgeableReceivers[receiverTypeName] else {
            skippedReasons[path] = "unbridged owning type '\(rawReceiver)'"; continue
        }
        let memberName = sym.pathComponents.last!
        let key = "static:\(receiverTypeName).\(memberName)"
        if !claim(key, clashLabel: "\(receiverTypeName).\(memberName)") { continue }
        guard let propType = extractType(
            from: sym.declarationFragments ?? [],
            selfType: recvType
        ), !propType.isOptional else {
            skippedReasons[path] = "non-value or optional static property"; continue
        }
        let valueExpr = render(propType.bridge.boxTemplate, "\(receiverTypeName).\(memberName)")
        record(key, bucket: .type(receiverTypeName), code: """
            \"static let \(receiverTypeName).\(memberName)\": .staticValue(\(valueExpr)),
        """)

    case "swift.type.method" where (2...3).contains(sym.pathComponents.count) && !isDeprecated(sym) && !isGeneric(sym) && !isAsync(sym):
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard bridgeableReceivers[receiverTypeName] != nil else {
            skippedReasons[path] = "unbridged owning type '\(rawReceiver)'"; continue
        }
        guard let sig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value parameter or return"; continue
        }
        let methodName = sym.names.title.split(separator: "(").first.map(String.init) ?? sym.names.title
        let key = "static-method:\(receiverTypeName).\(methodName)"
        if !claim(key, clashLabel: "\(receiverTypeName).\(methodName)") { continue }
        record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
            registerLine: "\"static func \(receiverTypeName).\(methodName)()\": .staticMethod",
            closureParams: "args",
            arity: sig.parameters.count,
            recvUnboxLine: nil,
            callExpr: "\(receiverTypeName).\(methodName)(\(unboxedCallArgs(for: sig)))",
            errorPrefix: "\(receiverTypeName).\(methodName)",
            returnType: sig.returnType,
            isOptional: sig.returnIsOptional,
            isThrowing: isThrowing(sym),
            isAsync: isAsync(sym),
            tupleElements: sig.returnTupleElements
        )))

    default:
        continue
    }
}

// MARK: - Generic-method pass (Encodable / Decodable)
//
// The main switch above skips `isGeneric(sym)` symbols because the
// generator can't pick concrete witnesses. For a small set of well-
// known constraints (`Encodable`, `Decodable`) the type-erasure
// strategy is fixed: wrap any Value in `ScriptCodable`. We detect the
// shape here and emit a generic-keyed entry whose body calls the real
// Foundation API on the wrapped Value. The runtime's signature matcher
// dispatches to it at call time — see `tryGenericMethodDispatch`.

for annotated in prioritizedSymbols {
    let sym = annotated.symbol
    guard sym.kind.identifier == "swift.method",
          (2...3).contains(sym.pathComponents.count),
          isGeneric(sym),
          !isMutating(sym),
          !isDeprecated(sym),
          !isAsync(sym)
    else { continue }
    let path = sym.pathComponents.joined(separator: ".")
    if blocklist.contains(path) { continue }
    if !autoAllowlist, !allowlist.contains(path) { continue }

    let receiverTypeName = sym.pathComponents.dropLast().joined(separator: ".")
    let methodName = sym.names.title.split(separator: "(").first.map(String.init) ?? sym.names.title

    let generics = sym.swiftGenerics?.parameters ?? []
    let allConstraints = sym.swiftGenerics?.constraints ?? []
    guard generics.count == 1 else { continue }
    let genericName = generics[0].name
    let conformances = allConstraints.filter {
        $0.kind == "conformance" && $0.lhs == genericName
    }
    guard conformances.count == 1 else { continue }
    let constraintRHS = conformances[0].rhs

    guard let frags = sym.declarationFragments,
          let parsed = parseGenericMethodFragments(frags)
    else { continue }

    let emitGroup = emitGroupFor(symbol: sym, module: annotated.module)
    let recvUnbox = "let recv: \(receiverTypeName) = try unboxOpaque(receiver, as: \(receiverTypeName).self, typeName: \"\(receiverTypeName)\")"

    func emitGenericEntry(claimKey: String, bucket: EmitBucket, code: String) {
        guard !registeredKeys.contains(claimKey) else { return }
        emitted.append(EmitEntry(
            symbolPath: path, group: emitGroup, bucket: bucket, code: code,
            platform: platform(forBridgeKey: claimKey)
        ))
        seenPaths.insert(path)
        registeredKeys.insert(claimKey)
    }

    switch constraintRHS {
    case "Encodable":
        // `func X.encode<T: Encodable>(_: T) throws -> Data`
        guard parsed.params.count == 1, parsed.params[0].type == genericName else { continue }
        guard parsed.returnType == "Data" else { continue }
        let key = "func \(receiverTypeName).\(methodName)<\(genericName): Encodable>(\(parsed.params[0].labelClause): \(genericName)) throws -> Data"
        let claimKey = "generic-method:\(key)"
        let code = """
                \"\(key)\": .method { receiver, args in
                    guard args.count == 1 else {
                        throw RuntimeError.invalid("\(receiverTypeName).\(methodName): expected 1 argument(s), got \\(args.count)")
                    }
                    \(recvUnbox)
                    do {
                        return .opaque(typeName: "Data", value: try recv.encode(ScriptCodable(args[0])))
                    } catch {
                        throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
                    }
                },
        """
        emitGenericEntry(claimKey: claimKey, bucket: .type(receiverTypeName), code: code)

    case "Decodable":
        // `func X.decode<T: Decodable>(_: T.Type, from: Data) throws -> T`
        guard parsed.params.count == 2,
              parsed.params[0].type == "\(genericName).Type",
              parsed.params[1].type == "Data"
        else { continue }
        guard parsed.returnType == genericName else { continue }
        let p0Label = parsed.params[0].labelClause
        let p1Label = parsed.params[1].labelClause
        let key = "func \(receiverTypeName).\(methodName)<\(genericName): Decodable>(\(p0Label): \(genericName).Type, \(p1Label): Data) throws -> \(genericName)"
        let claimKey = "generic-method:\(key)"
        // Decode body captures `[weak i]` to thread the interpreter
        // through `ScriptCodable.userInfo`, so it lives in the runtime
        // bucket (the manifest's register function) rather than a
        // static-let dict.
        let code = """
                i.bridges["\(key)"] = .method { [weak i] receiver, args in
                    guard let interp = i else {
                        throw RuntimeError.invalid("\(receiverTypeName).\(methodName): interpreter unavailable")
                    }
                    guard args.count == 2 else {
                        throw RuntimeError.invalid("\(receiverTypeName).\(methodName): expected 2 argument(s), got \\(args.count)")
                    }
                    \(recvUnbox)
                    guard case .opaque(typeName: "Metatype", let typeAny) = args[0],
                          let typeName = typeAny as? String
                    else {
                        throw RuntimeError.invalid("\(receiverTypeName).\(methodName): first argument must be a type (`T.self`)")
                    }
                    let data: Data = try unboxOpaque(args[1], as: Data.self, typeName: "Data")
                    do {
                        recv.userInfo[.scriptInterpreter] = interp
                        recv.userInfo[.scriptTargetType] = typeName
                        return try recv.decode(ScriptCodable.self, from: data).value
                    } catch {
                        throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
                    }
                }
        """
        emitGenericEntry(claimKey: claimKey, bucket: .runtime, code: code)

    default:
        continue
    }
}

// MARK: - OptionSet array-literal init pass
//
// OptionSet types (e.g. `JSONEncoder.OutputFormatting`) conform to
// `ExpressibleByArrayLiteral` via the protocol's default; their
// `init(arrayLiteral:)` takes a variadic `Element...` which the main
// emit pass rejects. We synthesise it directly from the conformance
// data: build via the empty `init()` then `formUnion` each element.
// This is what powers `encoder.outputFormatting = [.prettyPrinted,
// .sortedKeys]` at the call site — the runtime invokes this bridge
// after evaluating each `.case` against the property's type.
for (usr, bridge) in bridgedTypes {
    guard bridge.unboxTemplate.contains("unboxOpaque") else { continue }
    let conformances = conformancesByUSR[usr] ?? []
    guard conformances.contains(optionSetUSR) else { continue }
    let typeName = bridge.swiftSpelling
    let key = "init \(typeName)(arrayLiteral:)"
    let claimKey = "init:\(typeName)(arrayLiteral:)"
    if registeredKeys.contains(claimKey) { continue }
    let code = """
            \"\(key)\": .`init` { args in
                guard args.count == 1, case .array(let elements) = args[0] else {
                    throw RuntimeError.invalid("\(typeName)(arrayLiteral:): expected array literal")
                }
                var result = \(typeName)()
                for element in elements {
                    let item: \(typeName) = try unboxOpaque(
                        element, as: \(typeName).self, typeName: "\(typeName)"
                    )
                    result.formUnion(item)
                }
                return boxOpaque(result, typeName: "\(typeName)")
            },
    """
    let group: EmitGroup = usr.hasPrefix("s:10Foundation") || usr.hasPrefix("c:") ? .foundation : .stdlib
    // Array-literal init mirrors the underlying type's platform —
    // OptionSet types living in scl get cross-platform; Apple-only
    // ones get gated.
    emitted.append(EmitEntry(
        symbolPath: "\(typeName)(arrayLiteral:)",
        group: group, bucket: .type(typeName), code: code,
        platform: platform(forBridgeKey: "init \(typeName)(arrayLiteral:)")
    ))
    registeredKeys.insert(claimKey)
}

// Emit `registerComparator` calls for every bridged opaque type that
// conforms to `Equatable` (and use `<`/`>` ordering for those that also
// conform to `Comparable`). Lets script code write `dateA < dateB`,
// `localeA == localeB`, `urlA == urlB`, etc. without hand-rolling.
for (usr, bridge) in bridgedTypes {
    // Only opaque types — primitives are compared via `Value.==`.
    guard bridge.unboxTemplate.contains("unboxOpaque") else { continue }
    let conformances = conformancesByUSR[usr] ?? []
    guard conformances.contains(equatableUSR) else { continue }
    let isComparable = conformances.contains(comparableUSR)
    let typeName = bridge.swiftSpelling
    let body: String
    if isComparable {
        body = """
                guard case .opaque(_, let a) = lhs, let la = a as? \(typeName),
                      case .opaque(_, let b) = rhs, let lb = b as? \(typeName)
                else { throw RuntimeError.invalid("\(typeName) comparison: bad payloads") }
                return la < lb ? -1 : (la > lb ? 1 : 0)
        """
    } else {
        body = """
                guard case .opaque(_, let a) = lhs, let la = a as? \(typeName),
                      case .opaque(_, let b) = rhs, let lb = b as? \(typeName)
                else { throw RuntimeError.invalid("\(typeName) comparison: bad payloads") }
                return la == lb ? 0 : -1
        """
    }
    let code = """
            i.registerComparator(on: \"\(typeName)\") { lhs, rhs in
        \(body)
            }
    """
    // Foundation comparators go in the Foundation file (load on import);
    // any future stdlib opaque comparators would go in stdlib.
    let group: EmitGroup = usr.hasPrefix("s:10Foundation") || usr.hasPrefix("c:") ? .foundation : .stdlib
    // Comparators are runtime-time (writing to `opaqueComparators`,
    // not the bridges table), so they live in the manifest's runtime
    // block rather than a per-type dict.
    // Comparator references the type itself; classify by whether the
    // owning type exists on the cross-platform side. Reference-type
    // Foundation classes (URLSession, URLResponse, HTTPURLResponse,
    // FileManager …) are typealiases for AnyObject on Linux's scl
    // and don't conform to Equatable — `isTypeCrossPlatform` only
    // returns true for value types in scl, so those comparators get
    // gated automatically.
    let comparatorPlatform: Platform =
        (sclOracle?.isTypeCrossPlatform(typeName) ?? true)
        ? .crossPlatform : .appleOnly
    emitted.append(EmitEntry(
        symbolPath: "\(typeName).==", group: group, bucket: .runtime, code: code,
        platform: comparatorPlatform
    ))
}

// Report missing entries.
for entry in allowlist where !seenPaths.contains(entry) {
    let reason = skippedReasons[entry] ?? "not found in any symbol graph"
    FileHandle.standardError.write(Data("warning: \(entry): \(reason)\n".utf8))
}

// MARK: - Output

let autogenBanner = """
// AUTO-GENERATED by BridgeGeneratorTool. Do not edit by hand.
// Regenerate with: bash Tools/regen-foundation-bridge.sh

"""

/// Identifier-safe form of a type name: drop dots, lowercase the first
/// segment. `URL` → `url`; `String.Encoding` → `stringEncoding`.
func staticLetName(for typeName: String) -> String {
    let parts = typeName.split(separator: ".")
    guard let first = parts.first else { return "_unknown" }
    let head = first.prefix(1).lowercased() + first.dropFirst()
    let tail = parts.dropFirst().map { String($0) }.joined()
    return head + tail
}

/// Filename slug — same as `staticLetName` but PascalCase, used for
/// `<Bridge>+<TypeSlug>.swift` filenames.
func filenameSlug(for typeName: String) -> String {
    typeName.split(separator: ".").joined()
}

/// Convert a dict-literal-form entry (`"<key>": <body>,`) to assignment
/// form (`d["<key>"] = <body>`) so it can live inside a `#if`-gated
/// block of a closure-built dict. Used for Apple-only entries since
/// Swift doesn't allow `#if` inside an array/dict literal.
func toAssignmentForm(_ entry: String) -> String {
    let s = entry
    // Find leading whitespace (preserved in the output).
    let prefixWS = s.prefix(while: { $0 == " " || $0 == "\t" })
    let rest = s.dropFirst(prefixWS.count)
    guard rest.hasPrefix("\"") else { return entry }  // Unexpected shape; bail.
    // Walk the key respecting escape sequences.
    var idx = rest.index(after: rest.startIndex)
    while idx < rest.endIndex {
        let ch = rest[idx]
        if ch == "\\" {
            idx = rest.index(after: idx)
            if idx < rest.endIndex { idx = rest.index(after: idx) }
            continue
        }
        if ch == "\"" { break }
        idx = rest.index(after: idx)
    }
    guard idx < rest.endIndex else { return entry }
    let quotedKey = rest[rest.startIndex...idx]
    let afterKey = rest[rest.index(after: idx)...]
    // Skip ":" and following whitespace.
    var bodyStart = afterKey.startIndex
    while bodyStart < afterKey.endIndex,
          afterKey[bodyStart] == ":" || afterKey[bodyStart] == " "
    {
        bodyStart = afterKey.index(after: bodyStart)
    }
    var body = String(afterKey[bodyStart...])
    // Strip trailing comma (allowing trailing whitespace/newlines after).
    if let lastComma = body.lastIndex(of: ",") {
        let after = body[body.index(after: lastComma)...]
        if after.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            body = String(body[..<lastComma]) + String(after)
        }
    }
    return "\(prefixWS)d[\(quotedKey)] = \(body)"
}

/// Per-type entries split by platform classification.
struct PlatformedEntries {
    var crossPlatform: [String] = []   // dict-literal form
    var appleOnly: [String] = []       // dict-literal form (will be converted)
    var isEmpty: Bool { crossPlatform.isEmpty && appleOnly.isEmpty }
}

/// Render a per-type bridge file. Always emits a closure-built dict so
/// Apple-only entries can live inside `#if canImport(Darwin)` blocks
/// without reshaping the file. `nonisolated(unsafe)` opts the global
/// out of the strict-concurrency shared-state check — `Bridge`'s closure
/// cases aren't `@Sendable`, so the dict can't be plain `Sendable`. The
/// dict is read-only after init, so the bypass is safe in practice.
func renderPerTypeFile(
    namespace: String, typeName: String, entries: PlatformedEntries
) -> String {
    let dictName = staticLetName(for: typeName)
    if entries.appleOnly.isEmpty {
        // Pure cross-platform dict — emit the literal form directly.
        // `[:]` (not `[]`) is the empty-dict literal Swift accepts.
        let crossBody = entries.crossPlatform.isEmpty
            ? "        // (no entries)\n        :"
            : entries.crossPlatform.joined(separator: "\n")
        if entries.crossPlatform.isEmpty {
            return """
            \(autogenBanner)import Foundation
            #if canImport(FoundationNetworking)
            import FoundationNetworking
            #endif

            extension \(namespace) {
                nonisolated(unsafe) static let \(dictName): [String: Bridge] = [:]
            }

            """
        }
        return """
        \(autogenBanner)import Foundation
        #if canImport(FoundationNetworking)
        import FoundationNetworking
        #endif

        extension \(namespace) {
            nonisolated(unsafe) static let \(dictName): [String: Bridge] = [
        \(crossBody)
            ]
        }

        """
    }
    let appleBody = entries.appleOnly.map(toAssignmentForm).joined(separator: "\n")
    // When there are no cross-platform entries we still need a starter
    // dict for the Apple-only `d["..."] = ...` assignments — use `[:]`.
    let dictInit = entries.crossPlatform.isEmpty
        ? "        var d: [String: Bridge] = [:]"
        : "        var d: [String: Bridge] = [\n\(entries.crossPlatform.joined(separator: "\n"))\n        ]"
    return """
    \(autogenBanner)import Foundation
    #if canImport(FoundationNetworking)
    import FoundationNetworking
    #endif

    extension \(namespace) {
        nonisolated(unsafe) static let \(dictName): [String: Bridge] = {
    \(dictInit)
            #if canImport(Darwin)
    \(appleBody)
            #endif
            return d
        }()
    }

    """
}

/// Render the manifest file: declares the namespace, lists all per-type
/// dicts, and provides a single entry point that drains them into
/// `i.bridges` plus runs the runtime-time block (globals + comparators).
func renderManifest(
    namespace: String,
    extensionTarget: String,
    methodName: String,
    typeNames: [String],
    runtimeBodies: [String]
) -> String {
    let dictNames = typeNames.map(staticLetName(for:))
    let dictList = dictNames.map { "        \(namespace).\($0)," }.joined(separator: "\n")
    let runtimeBody = runtimeBodies.isEmpty
        ? "        // (no runtime registrations)"
        : runtimeBodies.joined(separator: "\n\n")
    return """
    \(autogenBanner)import Foundation
    #if canImport(FoundationNetworking)
    import FoundationNetworking
    #endif

    /// Namespace for the per-type bridge dicts. Each `static let` lives
    /// in its own file (`\(namespace)+<Type>.swift`) and contributes a
    /// chunk of `[String: Bridge]` entries; the installer below merges
    /// them all into the interpreter's flat dispatch table.
    enum \(namespace) {
        /// Aggregated view of every per-type dict — convenient for
        /// callers that want to introspect the full bridge surface.
        nonisolated(unsafe) static let all: [String: Bridge] = [
    \(dictList)
        ].reduce(into: [:]) { acc, dict in
            for (k, v) in dict { acc[k] = v }
        }
    }

    extension \(extensionTarget) {
        func \(methodName)(into i: Interpreter) {
            for (k, v) in \(namespace).all { i.bridges[k] = v }
    \(runtimeBody)
        }
    }

    """
}

/// Group the type-bucket emits by their `typeName`, preserving the
/// order in which they were added (which is the priority-sorted order
/// from the symbol walk). Each group's entries are partitioned into
/// cross-platform (kept in the dict literal) and Apple-only (emitted
/// inside `#if canImport(Darwin)` as assignment statements).
func groupedByType(_ entries: [EmitEntry]) -> [(String, PlatformedEntries)] {
    var order: [String] = []
    var bodies: [String: PlatformedEntries] = [:]
    for entry in entries {
        guard case .type(let name) = entry.bucket else { continue }
        if bodies[name] == nil { order.append(name) }
        var current = bodies[name] ?? PlatformedEntries()
        switch entry.platform {
        case .crossPlatform: current.crossPlatform.append(entry.code)
        case .appleOnly:     current.appleOnly.append(entry.code)
        }
        bodies[name] = current
    }
    return order.map { ($0, bodies[$0]!) }
}

/// Runtime-time bodies (globals, comparators). Apple-only entries get
/// wrapped in `#if canImport(Darwin)` so Linux/Windows builds skip
/// them entirely.
func runtimeBodies(_ entries: [EmitEntry]) -> [String] {
    entries.compactMap { entry in
        guard case .runtime = entry.bucket else { return nil }
        switch entry.platform {
        case .crossPlatform:
            return entry.code
        case .appleOnly:
            return "#if canImport(Darwin)\n\(entry.code)\n#endif"
        }
    }
}

let stdlibEntries = emitted.filter { $0.group == .stdlib }
let foundationEntries = emitted.filter { $0.group == .foundation }

let stdlibTypes = groupedByType(stdlibEntries)
let foundationTypes = groupedByType(foundationEntries)

let stdlibRuntime = runtimeBodies(stdlibEntries)
let foundationRuntime = runtimeBodies(foundationEntries)

func writeOutputs(
    namespace: String,
    extensionTarget: String,
    methodName: String,
    types: [(String, PlatformedEntries)],
    runtime: [String],
    outputDir: URL
) throws -> Int {
    // Wipe stale per-type files. Anything matching `<namespace>+*.swift`
    // gets removed first so a renamed type doesn't leave orphans behind.
    let fm = FileManager.default
    if let contents = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil) {
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(namespace) && name.hasSuffix(".swift") {
                try? fm.removeItem(at: url)
            }
        }
    } else {
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }
    var count = 0
    for (typeName, entries) in types {
        let file = outputDir.appendingPathComponent(
            "\(namespace)+\(filenameSlug(for: typeName)).swift"
        )
        let contents = renderPerTypeFile(namespace: namespace, typeName: typeName, entries: entries)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        count += entries.crossPlatform.count + entries.appleOnly.count
    }
    let manifest = outputDir.appendingPathComponent("\(namespace).swift")
    let manifestContents = renderManifest(
        namespace: namespace,
        extensionTarget: extensionTarget,
        methodName: methodName,
        typeNames: types.map(\.0),
        runtimeBodies: runtime
    )
    try manifestContents.write(to: manifest, atomically: true, encoding: .utf8)
    return count + runtime.count
}

do {
    let stdlibDir = outputStdlibURL.deletingLastPathComponent()
        .appendingPathComponent("StdlibBridge")
    let foundationDir = outputFoundationURL.deletingLastPathComponent()
        .appendingPathComponent("FoundationBridge")
    let stdlibCount = try writeOutputs(
        namespace: "StdlibBridges",
        extensionTarget: "Interpreter",
        methodName: "registerGeneratedStdlib",
        types: stdlibTypes,
        runtime: stdlibRuntime,
        outputDir: stdlibDir
    )
    let foundationCount = try writeOutputs(
        namespace: "FoundationBridges",
        extensionTarget: "FoundationModule",
        methodName: "registerGenerated",
        types: foundationTypes,
        runtime: foundationRuntime,
        outputDir: foundationDir
    )
    // Remove the legacy single-file outputs; they're replaced by the
    // per-type-file directory layout.
    try? FileManager.default.removeItem(at: outputStdlibURL)
    try? FileManager.default.removeItem(at: outputFoundationURL)
    print("wrote \(stdlibCount) stdlib bridge(s) across \(stdlibTypes.count) type(s) under \(stdlibDir.path)")
    print("wrote \(foundationCount) Foundation bridge(s) across \(foundationTypes.count) type(s) under \(foundationDir.path)")
} catch {
    FileHandle.standardError.write(Data("error writing output: \(error)\n".utf8))
    exit(1)
}
