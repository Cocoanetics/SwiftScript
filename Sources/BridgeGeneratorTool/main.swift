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
        // For nested types (`DateComponentsFormatter.ZeroFormattingBehavior`),
        // walk up the dotted path — if any ancestor is unavailable, the
        // nested type is too.
        var ancestor = typeName
        while let dot = ancestor.lastIndex(of: ".") {
            ancestor = String(ancestor[..<dot])
            if unavailableTypes.contains(ancestor) { return false }
            if unavailableTypes.contains("NS\(ancestor)") { return false }
        }
        if crossPlatform.contains("\(typeName).") { return true }
        // NS-prefixed fallback.
        let nsCandidate: String
        if let dot = typeName.firstIndex(of: ".") {
            nsCandidate = "NS\(typeName[..<dot])\(typeName[dot...])."
        } else {
            nsCandidate = "NS\(typeName)."
        }
        if unavailableTypes.contains(String(nsCandidate.dropLast())) { return false }
        if crossPlatform.contains(nsCandidate) { return true }
        // For nested types: if neither the type nor its NS-prefixed
        // form is in the cross-platform set, it's Apple-only.
        return false
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
    // Fixed-width integers and Float cross the boundary as script
    // `.int` / `.double` with range-checked narrowing on the way in
    // (`toInt32` throws on overflow instead of truncating). Unsigned
    // 64-bit results wider than Int.max throw on the way out.
    "s:s4Int8V": BridgedType(
        swiftSpelling: "Int8",
        unboxTemplate: "try toInt8(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s5Int16V": BridgedType(
        swiftSpelling: "Int16",
        unboxTemplate: "try toInt16(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s5Int32V": BridgedType(
        swiftSpelling: "Int32",
        unboxTemplate: "try toInt32(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s5Int64V": BridgedType(
        swiftSpelling: "Int64",
        unboxTemplate: "try toInt64(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s5UInt8V": BridgedType(
        swiftSpelling: "UInt8",
        unboxTemplate: "try toUInt8(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s6UInt16V": BridgedType(
        swiftSpelling: "UInt16",
        unboxTemplate: "try toUInt16(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s6UInt32V": BridgedType(
        swiftSpelling: "UInt32",
        unboxTemplate: "try toUInt32(%@)", boxTemplate: ".int(Int(%@))"),
    "s:s6UInt64V": BridgedType(
        swiftSpelling: "UInt64",
        unboxTemplate: "try toUInt64(%@)", boxTemplate: "try boxUnsignedAsInt(%@)"),
    "s:Su": BridgedType(
        swiftSpelling: "UInt",
        unboxTemplate: "try toUInt(%@)", boxTemplate: "try boxUnsignedAsInt(%@)"),
    "s:Sf": BridgedType(
        swiftSpelling: "Float",
        unboxTemplate: "try toFloat(%@)", boxTemplate: ".double(Double(%@))"),
]

// MARK: - Composite (collection / optional) bridges
//
// Collections and optionals compose element bridges into new
// unbox/box templates, so `[String]`, `[String: String]`, `Set<Int>`
// and `T?` parameters ride the same machinery as bare nominals.
// This is the single change that unlocks the widest slice of
// Foundation (issue #7 root cause 1).

/// Element bridges whose *box* template itself throws (`UInt64` /
/// `UInt` overflow checks) can't nest inside a collection box — the
/// emitted `.map` would rethrow without a `try` in scope when the
/// underlying call is non-throwing. Composite builders reject them.
func isComposableElement(_ b: BridgedType) -> Bool {
    !b.boxTemplate.contains("try ")
}

func arrayBridge(of element: BridgedType) -> BridgedType? {
    guard isComposableElement(element) else { return nil }
    return BridgedType(
        swiftSpelling: "[\(element.swiftSpelling)]",
        unboxTemplate: "try unboxArray(%@).map { \(render(element.unboxTemplate, "$0")) }",
        boxTemplate: ".array(%@.map { \(render(element.boxTemplate, "$0")) })"
    )
}

func dictBridge(key: BridgedType, value: BridgedType) -> BridgedType? {
    guard isComposableElement(key), isComposableElement(value) else { return nil }
    return BridgedType(
        swiftSpelling: "[\(key.swiftSpelling): \(value.swiftSpelling)]",
        unboxTemplate: "Dictionary(uniqueKeysWithValues: try unboxDict(%@).map { (\(render(key.unboxTemplate, "$0.key")), \(render(value.unboxTemplate, "$0.value"))) })",
        boxTemplate: ".dict(%@.map { DictEntry(key: \(render(key.boxTemplate, "$0.key")), value: \(render(value.boxTemplate, "$0.value"))) })"
    )
}

func setBridge(of element: BridgedType) -> BridgedType? {
    guard isComposableElement(element) else { return nil }
    return BridgedType(
        swiftSpelling: "Set<\(element.swiftSpelling)>",
        unboxTemplate: "Set(try unboxSet(%@).map { \(render(element.unboxTemplate, "$0")) })",
        boxTemplate: ".set(%@.map { \(render(element.boxTemplate, "$0")) })"
    )
}

/// Optional *parameter* wrapper: unboxes `.optional(x)` / bare values
/// to `T?`. (Optional returns keep the `isOptional` flag + `if let`
/// path in `buildReturnExpr` — this wrapper is for input slots, so
/// its box template is never emitted.)
func optionalParamBridge(of inner: BridgedType) -> BridgedType {
    BridgedType(
        swiftSpelling: "\(inner.swiftSpelling)?",
        unboxTemplate: "try unboxOptionalValue(%@).map { \(render(inner.unboxTemplate, "$0")) }",
        boxTemplate: ".optional(%@.map { \(render(inner.boxTemplate, "$0")) })"
    )
}

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
    // File-IO doors. Each gets path/URL gating in `gates(...)` so a
    // script can't open a file outside the sandbox via a class init
    // (FileHandle(forReadingAtPath:), Bundle(path:), etc.).
    "FileHandle",
    "Bundle",
    "InputStream",
    "OutputStream",
    "FileWrapper",
    // Subprocess: denied entirely under a sandbox via `gates(...)`.
    // `Foundation.Process` spawns a real OS subprocess that escapes
    // every host gate; the bridge throws `ProcessSandboxDenied` when
    // a sandbox is configured.
    "Process",
    // Date parsing/formatting — the everyday scripting idiom
    // (`DateFormatter().dateFormat = …; .date(from:)`) is entirely
    // value-shaped: String properties and Date?/String returns.
    "DateFormatter",
    "ISO8601DateFormatter",
    // Pipe wires Process stdio for standalone pipelines; its
    // fileHandleForReading/Writing return the already-bridged
    // FileHandle. No path args to gate — Process itself is the
    // sandbox-denied door. (Thread deliberately stays unbridged:
    // `Thread.sleep` is `noasync` and every bridge closure is async
    // — the wait primitive is `Task.sleep`, hand-bridged in
    // ConcurrencyModule.)
    "Pipe",
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
    // Array (`[T]`), dict (`[K: V]`) and `Set<T>` spellings hand off
    // to the collection extractor, which composes the element bridges
    // into list/dict/set templates. Tuples, closures, existentials
    // and other generics stay rejected. The bare-nominal case has
    // nothing before the typeIdentifier except the parameter name
    // and `: `.
    let textFrags = fragments.filter { $0.kind == "text" }
    let combinedText = textFrags.map(\.spelling).joined()
    if combinedText.contains("[") || combinedText.contains("<") ||
       combinedText.contains("(") || combinedText.contains("&") ||
       combinedText.contains("any ") || combinedText.contains("some ")
    {
        return extractCollectionType(from: fragments, selfType: selfType)
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

/// Parse `[T]`, `[K: V]` and `Set<T>` spellings out of a fragment
/// list, composing element bridges via `arrayBridge`/`dictBridge`/
/// `setBridge`. A trailing `?` yields `isOptional` (the *collection*
/// optional). Nested collections, tuples, closures and unbridgeable
/// elements return nil.
func extractCollectionType(
    from fragments: [SymbolGraph.Fragment],
    selfType: BridgedType?
) -> ExtractedType? {
    // Tokenize: text fragments contribute punctuation; typeIdentifier
    // fragments become element references. Parsing starts at the
    // first `[` or at a `Set` identifier so parameter-name prefixes
    // ("paths: [") don't confuse the grammar.
    enum Token: Equatable {
        case lbracket, rbracket, colon, lt, gt, dot, question
        case tid(Int)   // index into `fragments`
    }
    var tokens: [Token] = []
    var started = false
    scan: for (i, f) in fragments.enumerated() {
        if f.kind == "typeIdentifier" {
            if !started && f.spelling == "Set" { started = true }
            if started { tokens.append(.tid(i)) }
            continue
        }
        guard f.kind == "text" else {
            if started { return nil }
            continue
        }
        for ch in f.spelling {
            if !started {
                if ch == "[" { started = true } else { continue }
            }
            switch ch {
            case "[": tokens.append(.lbracket)
            case "]": tokens.append(.rbracket)
            case ":": tokens.append(.colon)
            case "<": tokens.append(.lt)
            case ">": tokens.append(.gt)
            case ".": tokens.append(.dot)
            case "?": tokens.append(.question)
            case " ", "\t", "\n": break
            case "{", "=":
                // Accessor block (`{ get set }`) or default value —
                // the type spelling is over.
                break scan
            default:
                // Any other character (tuple parens, `->`, variadic
                // dots handled via `.dot` runs below, generic angle
                // contents…) means this isn't a plain collection.
                return nil
            }
        }
    }
    guard started, !tokens.isEmpty else { return nil }

    // Trailing `?` marks the optional collection.
    var isOptional = false
    if tokens.last == .question {
        isOptional = true
        tokens.removeLast()
    }
    // Any remaining `?` (optional elements) is out of scope.
    if tokens.contains(.question) { return nil }

    /// Resolve a dotted element — one or more `tid` tokens separated
    /// by `.dot` — to the leaf identifier's bridge, mirroring
    /// `extractType`'s use of the last (leaf) USR.
    func parseElement(_ slice: ArraySlice<Token>) -> BridgedType? {
        var expectTid = true
        var leaf: Int?
        for t in slice {
            switch (t, expectTid) {
            case (.tid(let i), true): leaf = i; expectTid = false
            case (.dot, false): expectTid = true
            default: return nil
            }
        }
        guard !expectTid, let leaf else { return nil }
        let frag = fragments[leaf]
        if frag.spelling == "Self", let selfType { return selfType }
        guard let usr = frag.preciseIdentifier else { return nil }
        return bridgedTypes[usr]
    }

    // `Set<Element>`
    if case .tid(let i)? = tokens.first, fragments[i].spelling == "Set" {
        guard tokens.count >= 4, tokens[1] == .lt, tokens.last == .gt,
              let element = parseElement(tokens[2..<(tokens.count - 1)]),
              let composed = setBridge(of: element)
        else { return nil }
        return ExtractedType(bridge: composed, isOptional: isOptional)
    }
    // `[Element]` / `[Key: Value]`
    guard tokens.first == .lbracket, tokens.last == .rbracket else { return nil }
    let inner = tokens[1..<(tokens.count - 1)]
    if inner.contains(.lbracket) || inner.contains(.lt) { return nil }  // no nesting
    if let colonAt = inner.firstIndex(of: .colon) {
        guard let key = parseElement(inner[inner.startIndex..<colonAt]),
              let value = parseElement(inner[(colonAt + 1)...]),
              let composed = dictBridge(key: key, value: value)
        else { return nil }
        return ExtractedType(bridge: composed, isOptional: isOptional)
    }
    guard let element = parseElement(inner),
          let composed = arrayBridge(of: element)
    else { return nil }
    return ExtractedType(bridge: composed, isOptional: isOptional)
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
    /// Per-kept-parameter "has a default value" flags, parallel to
    /// `parameters`. Drives `signatureVariants(_:)` — a defaulted
    /// suffix can be omitted at the Swift call site, so each
    /// omission gets its own label-keyed bridge entry
    /// (`URLRequest(url:)` alongside `URLRequest(url:timeoutInterval:)`).
    var parameterHasDefault: [Bool] = []
}

/// The signature itself plus one variant per omittable defaulted
/// suffix, shortest first (so the bare-key alias binds the simplest
/// call shape). Claims dedupe collisions with genuine overloads.
func signatureVariants(_ sig: ResolvedSignature) -> [ResolvedSignature] {
    var variants: [ResolvedSignature] = []
    var params = sig.parameters
    var flags = sig.parameterHasDefault
    while let last = flags.last, last {
        params.removeLast()
        flags.removeLast()
        variants.append(ResolvedSignature(
            parameters: params,
            returnType: sig.returnType,
            returnIsOptional: sig.returnIsOptional,
            returnTupleElements: sig.returnTupleElements,
            parameterHasDefault: flags
        ))
    }
    return variants.reversed() + [sig]
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
    guard let sig = sym.functionSignature else {
        // Some ObjC-imported zero-arg methods (`Process.waitUntilExit`)
        // carry no functionSignature at all. When the declaration
        // shows a bare `name()` with no return arrow, that IS the
        // signature: no params, Void.
        let frags = sym.declarationFragments ?? []
        let spelling = frags.map(\.spelling).joined()
        if sym.names.title.hasSuffix("()"), !spelling.contains("->") {
            return ResolvedSignature(
                parameters: [], returnType: nil,
                returnIsOptional: false, returnTupleElements: [],
                parameterHasDefault: [])
        }
        return nil
    }
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
    var paramHasDefault: [Bool] = []
    for (i, (label, p)) in zip(labels, paramSyntaxes).enumerated() {
        if let t = extractType(from: p.declarationFragments, selfType: selfBridge) {
            // Optional inputs wrap the element bridge so `.optional`
            // boxes (and bare values) unbox to `T?` at the call.
            params.append((label, t.isOptional ? optionalParamBridge(of: t.bridge) : t.bridge))
            paramHasDefault.append(i < defaults.count && defaults[i])
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
        if typeFrags.count == 1, typeFrags[0].spelling == "Void" {
            // Explicit `-> Void` (ObjC-imported methods spell it as a
            // typeIdentifier) — same as no return.
        } else if !typeFrags.isEmpty {
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
        returnTupleElements: retTupleElements,
        parameterHasDefault: paramHasDefault
    )
}

/// Render a unbox/box step using the BridgedType's template.
func render(_ template: String, _ expr: String) -> String {
    return template.replacingOccurrences(of: "%@", with: expr)
}

// MARK: - Sandbox / network gating policy

/// What kind of host resource a bridge body touches at runtime.
/// Controls which `authorize…` call gets injected into the generated
/// closure and how the call args are reshaped to use the bound names.
enum GateKind {
    case fsRead
    case fsWrite
    case fsDelete
    case network
    /// Network gate that pulls the URL+method out of a `URLRequest`
    /// arg. The bound name binds the request itself; the gate-emit
    /// step uses `\(name).url` and `\(name).httpMethod` to reach the
    /// authorize call.
    case networkRequest
}

/// Parameter labels that carry a `String`-typed filesystem path.
/// Receiver-driven rules consult this set as part of the per-arg scan
/// (in addition to the conventional first-arg-is-path heuristic for
/// FileManager). Membership here means "this label is a path; the
/// intent is fsRead by default unless the receiver/method overrides".
let pathStringLabelsRead: Set<String> = [
    "atPath", "atFilePath", "fromFile",
    "forReadingAtPath",
    "contentsOfFile", "withContentsOfFile", "atFile",
    // FileManager second-arg labels. `andPath` covers
    // `contentsEqual(atPath:andPath:)`; without it the comparison's
    // second path slipped past the gate.
    "andPath",
    // Bundle init / open-by-path doors. `path` is widespread in
    // Foundation but only the I/O receivers in `gates(...)` reach
    // this set, so keeping it here doesn't gate unrelated APIs.
    "path", "filePath", "fileAtPath",
]
/// As above, but for write-shaped path labels.
let pathStringLabelsWrite: Set<String> = [
    "toFile", "forWritingAtPath", "toFileAtPath",
    // `forUpdating*` opens for read+write — be conservative and gate
    // as a write so a sandbox that allows read but not write still
    // denies the open.
    "forUpdatingAtPath",
    // FileManager second-arg labels for `copyItem(atPath:toPath:)`,
    // `moveItem(atPath:toPath:)`, `linkItem(atPath:toPath:)`. The
    // first arg is gated by the receiver-rule's positional fallback;
    // the label scan picks up the second.
    "toPath", "andDestinationPath",
]
/// Parameter labels that carry a `URL`-typed filesystem-or-network
/// resource. Combined with the receiver/method intent to pick the
/// gate kind. `at` and `to` map to the same intent as the method
/// itself (read for `String(contentsOf:)`, write for `Data.write(to:)`,
/// etc.). The catch-all set below leans read; write-shaped methods
/// should be looked up in the receiver-rule's `writeMethods`.
let urlLabelsRead: Set<String> = [
    "at", "from", "url", "contentsOf", "forResource",
    "withContentsOf", "fileURL",
    // FileManager `setUbiquitous(_:itemAt:destinationURL:)` and
    // similar "URL of the item being acted on" labels.
    "itemAt", "ofItemAt",
]
let urlLabelsWrite: Set<String> = [
    "to", "atURL", "toURL", "destinationURL",
    "withDestinationURL",
]

/// One gate to inject: bind `args[index]` to a local name, then call
/// the appropriate authorizer. The bound name replaces the inline
/// `try unbox…` in the call expression so we don't double-unbox.
struct GateDirective {
    /// The arg index this gate applies to.
    let argIndex: Int
    /// Source-Swift type of the arg as bound. Driven by the symbol's
    /// `BridgedType.swiftSpelling`.
    let argSwiftType: String
    /// Local-variable name used in the bound let + the call site.
    let boundName: String
    /// Kind of resource — picks the authorize function to call.
    let kind: GateKind
}

/// Decide which gates apply to a method/init based on its receiver,
/// method name, and the resolved signature. Returns an empty array
/// when no gating is needed (the default — most bridges pass through
/// untouched).
///
/// The policy is intentionally conservative: gate every path-bearing
/// or URL-bearing arg of a known I/O receiver, even when the host
/// method itself is read-only metadata (`fileExists`, `attributesOfItem`).
/// Embedders that want cheaper introspection can grant a permissive
/// sandbox; the policy stays simple.
///
/// The receiver-driven rules also do a generalised per-parameter scan
/// across all positions: every `String`/`URL` arg whose label looks
/// path-bearing (`pathStringLabelsRead/Write`, `urlLabelsRead/Write`)
/// gets a gate at its position, not just position 0. That closes the
/// holes around methods like `FileManager.setUbiquitous(_:itemAt:
/// destinationURL:)` (where the URL args sit at indices 1+2) and
/// `createSymbolicLink(at:withDestinationURL:)` (both URLs are
/// writes). The receiver-rule supplies a *default intent*; the label
/// scan upgrades it to a more specific intent when the label says so.
///
/// The argLabels parameter carries the per-position call-site labels
/// (extracted from `sym.names.title`) used by the label scan. Receivers
/// without a known I/O personality return `[]` regardless of labels —
/// labels alone don't unlock gating, the receiver has to opt in.
func gates(
    forReceiver receiverTypeName: String?,
    methodName: String?,
    initFor: String? = nil,
    argLabels: [String] = [],
    signature sig: ResolvedSignature
) -> [GateDirective] {
    var directives: [GateDirective] = []
    var gatedIndices: Set<Int> = []

    /// Gate a `String`/`URL` parameter by absolute position. Skips
    /// non-path-shaped args silently so callers can fire-and-forget
    /// across an unknown signature. `replace` lets a later, more
    /// specific call upgrade the intent (e.g. label scan finding a
    /// `to:` write where the receiver default was read).
    func gatePathish(
        _ paramIndex: Int,
        kind: GateKind,
        replace: Bool = false
    ) {
        guard paramIndex < sig.parameters.count else { return }
        let p = sig.parameters[paramIndex]
        let spelling = p.type.swiftSpelling
        guard spelling == "String" || spelling == "URL" else { return }
        if gatedIndices.contains(paramIndex) {
            if replace, let i = directives.firstIndex(where: { $0.argIndex == paramIndex }) {
                directives[i] = GateDirective(
                    argIndex: paramIndex,
                    argSwiftType: spelling,
                    boundName: "arg\(paramIndex)",
                    kind: kind)
            }
            return
        }
        directives.append(GateDirective(
            argIndex: paramIndex,
            argSwiftType: spelling,
            boundName: "arg\(paramIndex)",
            kind: kind))
        gatedIndices.insert(paramIndex)
    }

    /// `URLRequest`-typed args route to the `.networkRequest` gate
    /// (URL + method extracted from the request struct). Used for
    /// the URLSession overloads that take a `URLRequest`
    /// (`data(for:)`, `upload(for:fromFile:)`, `download(for:)`, …)
    /// so the network policy fires the same as the bare-URL
    /// overloads.
    func gateURLRequest(_ paramIndex: Int) {
        guard paramIndex < sig.parameters.count else { return }
        let p = sig.parameters[paramIndex]
        guard p.type.swiftSpelling == "URLRequest" else { return }
        if gatedIndices.contains(paramIndex) { return }
        directives.append(GateDirective(
            argIndex: paramIndex,
            argSwiftType: "URLRequest",
            boundName: "arg\(paramIndex)",
            kind: .networkRequest))
        gatedIndices.insert(paramIndex)
    }

    /// Walk every parameter and gate any `String`/`URL` arg whose
    /// label appears in the path/URL label sets. Pulls intent from
    /// the label (writeLabels → fsWrite, readLabels → fsRead). The
    /// `defaultIntent` applies when the label doesn't disambiguate
    /// — typically the method-name-driven receiver-rule intent.
    /// Skips already-gated indices so a receiver's positional rule
    /// (e.g. URLSession's index-0 URL = .network) wins over the
    /// generic label scan.
    func scanByLabel(defaultIntent: GateKind) {
        for (i, label) in argLabels.enumerated() {
            guard i < sig.parameters.count else { break }
            if gatedIndices.contains(i) { continue }
            let p = sig.parameters[i]
            let spelling = p.type.swiftSpelling
            guard spelling == "String" || spelling == "URL" else { continue }
            let intent: GateKind?
            if spelling == "String" {
                if pathStringLabelsWrite.contains(label) { intent = .fsWrite }
                else if pathStringLabelsRead.contains(label) { intent = .fsRead }
                else { intent = nil }
            } else {  // URL
                if urlLabelsWrite.contains(label) { intent = defaultIntent.isWrite ? defaultIntent : .fsWrite }
                else if urlLabelsRead.contains(label) { intent = defaultIntent }
                else { intent = nil }
            }
            guard let intent else { continue }
            gatePathish(i, kind: intent)
        }
    }

    // FileManager — every method that takes a path or URL. The
    // receiver-rule picks the *default intent* by method name; the
    // label scan that follows then catches index-1+ URL/path args
    // (e.g. `setUbiquitous(_: Bool, itemAt: URL, destinationURL: URL)`,
    // `createSymbolicLink(at: URL, withDestinationURL: URL)`) that
    // the prior position-0/1 rule missed.
    if receiverTypeName == "FileManager" || initFor == "FileManager" {
        // `containerURL(forSecurityApplicationGroupIdentifier:)`
        // takes a security group *identifier*, not a path. Gating it
        // would now also rewrite the identifier to a resolved host
        // path (the fs gates rebind their arg to `authorizePath`'s
        // return), corrupting the lookup. The returned container URL
        // is host-spelled; any subsequent I/O on it is gated at the
        // consuming call, and under a `PathMapping` a host spelling
        // resolves to the unmapped sentinel and is denied.
        if methodName == "containerURL" { return directives }
        let writeMethods: Set<String> = [
            "createDirectory", "createFile", "createSymbolicLink",
            "setAttributes", "changeCurrentDirectoryPath",
            "linkItem", "copyItem", "moveItem", "replaceItemAt",
            "setUbiquitous",
        ]
        let deleteMethods: Set<String> = ["removeItem", "trashItem"]
        let intent: GateKind
        if let m = methodName {
            if deleteMethods.contains(m) { intent = .fsDelete }
            else if writeMethods.contains(m) { intent = .fsWrite }
            else { intent = .fsRead }
        } else { intent = .fsRead }
        // Position-0 fallback for the rare overloads whose label
        // doesn't appear in our sets (older Foundation kept some as
        // unlabeled `_`).
        gatePathish(0, kind: intent)
        scanByLabel(defaultIntent: intent)
    }

    // URL initializers — pure construction, not gated at init time.
    // `Sandbox.authorize` is async; many URL inits are sync. The gate
    // fires at the I/O call site (URLSession.data(from:),
    // String(contentsOf:), …) regardless of how the URL was built.

    // String / Data / NSString / NSData / CharacterSet file-IO inits
    // — read-shaped (`init X(contentsOf:)`, `init X(contentsOfFile:)`)
    // take a path/URL at index 0; the label-scan picks up
    // `contentsOf` / `contentsOfFile` directly. CharacterSet is here
    // because `CharacterSet(contentsOfFile:)` reads a bitmap
    // representation off disk — previously the only file-reading
    // init that shipped ungated.
    if initFor == "String" || initFor == "Data"
        || initFor == "NSString" || initFor == "NSData"
        || initFor == "CharacterSet"
    {
        if let m = methodName, m.contains("contentsOfFile") || m.contains("contentsOf") {
            gatePathish(0, kind: .fsRead)
            scanByLabel(defaultIntent: .fsRead)
        }
    }
    if receiverTypeName == "String" || receiverTypeName == "Data"
        || receiverTypeName == "NSString" || receiverTypeName == "NSData"
    {
        if methodName == "write" {
            gatePathish(0, kind: .fsWrite)
            scanByLabel(defaultIntent: .fsWrite)
        }
    }

    // URLSession — first arg is a network destination (URL or
    // URLRequest); the `fromFile:` overloads carry a local-file URL
    // at a later index that needs an fsRead gate. The label-scan
    // generalises this to any `fromFile:` / `from:` / `forResource:`
    // URL arg at any position.
    if receiverTypeName == "URLSession" {
        gatePathish(0, kind: .network)
        gateURLRequest(0)
        // Position-1 fsRead retained as a fallback for symbol graphs
        // whose label spelling doesn't make it through the extractor.
        gatePathish(1, kind: .fsRead)
        scanByLabel(defaultIntent: .fsRead)
    }

    // FileHandle — `init(forReadingAtPath:)`,
    // `init(forWritingAtPath:)`, `init(forUpdatingAtPath:)` plus the
    // URL-init variants `init(forReadingFrom:)`, `init(forWritingTo:)`,
    // `init(forUpdating:)`. The String-arg labels are in the
    // `pathStringLabels*` sets; the URL-arg labels (`forWritingTo` /
    // `forUpdating`) aren't in `urlLabelsWrite` because they're
    // FileHandle-specific spellings, so we infer the intent from the
    // method-label here and fall through to a positional gate.
    // `init(fileDescriptor:)` is out of scope — there's no path to
    // authorise. Methods on an opened FileHandle (read/write/seek)
    // are not gated here; the host process already constrains those
    // via fd permissions established at open time.
    if initFor == "FileHandle" {
        let intent: GateKind
        if let m = methodName,
           m.contains("forWriting") || m.contains("forUpdating")
        {
            intent = .fsWrite
        } else {
            intent = .fsRead
        }
        scanByLabel(defaultIntent: intent)
        if directives.isEmpty { gatePathish(0, kind: intent) }
    }

    // Bundle — `init(path:)`, `init(url:)` open a bundle root the
    // script later reads resources from. Gate as `.fsRead` so a
    // pathological root (`/etc`) gets denied. The static resource
    // enumerators that take a raw host directory under `inDirectory:`
    // (`Bundle.paths(forResourcesOfType:inDirectory:)` & friends) are
    // blocklisted rather than gated — their directory arg is often
    // `String?`, which the gate can't rewrite, and Bundle's other
    // String args (`localizedString(forKey:value:table:)`) are not
    // paths, so a blanket positional gate would mis-authorize them.
    if initFor == "Bundle" || receiverTypeName == "Bundle" {
        scanByLabel(defaultIntent: .fsRead)
    }

    // OutputStream — `init(toFileAtPath:append:)`,
    // `init(url:append:)` open a file for writing.
    if initFor == "OutputStream" {
        scanByLabel(defaultIntent: .fsWrite)
    }

    // InputStream — `init(fileAtPath:)`, `init(url:)` open a file
    // for reading.
    if initFor == "InputStream" {
        scanByLabel(defaultIntent: .fsRead)
    }

    // FileWrapper — `init(url:options:)` reads a wrapper from disk;
    // `.read(from:options:)` is read-shaped; `.write(to:options:
    // originalContentsURL:)` is write-shaped. The label-scan catches
    // each via `at` (read) / `to` (write) / `originalContentsURL`
    // (read of the prior copy).
    if initFor == "FileWrapper" {
        scanByLabel(defaultIntent: .fsRead)
    }
    if receiverTypeName == "FileWrapper" {
        let intent: GateKind
        if methodName == "write" { intent = .fsWrite }
        else { intent = .fsRead }
        // `matchesContents(of:)` carries the URL under the `of:`
        // label which isn't in `urlLabelsRead` (too generic to add
        // globally — appears all over Foundation on non-URL args).
        // Gate index 0 positionally so any URL-typed first arg on
        // FileWrapper is authorised; the label scan still upgrades
        // higher-index args (e.g. `originalContentsURL:`).
        gatePathish(0, kind: intent)
        scanByLabel(defaultIntent: intent)
    }

    return directives
}

/// Receivers (and init owners) whose path/URL args are sandbox-gated.
/// Optional `String?`/`URL?` params slide past `gatePathish`'s
/// spelling check, so a path-labelled optional arg on one of these
/// receivers can't be gated — and an ungated path is a sandbox hole.
/// Such symbols are skipped outright rather than half-gated.
let gatedIOReceivers: Set<String> = [
    "FileManager", "FileHandle", "InputStream", "OutputStream",
    "FileWrapper", "Bundle", "URLSession",
    "String", "Data", "NSString", "NSData", "CharacterSet",
]

/// True when a symbol on a gated IO receiver carries an optional
/// path-shaped arg that `gates(...)` cannot rewrite — the symbol
/// must be skipped, not emitted ungated.
func hasUngatablePathParam(
    receiver: String?,
    initFor: String?,
    argLabels: [String],
    signature sig: ResolvedSignature
) -> Bool {
    let owner = receiver ?? initFor
    guard let owner, gatedIOReceivers.contains(owner) else { return false }
    func optionalPathish(_ i: Int) -> Bool {
        guard i < sig.parameters.count else { return false }
        let spelling = sig.parameters[i].type.swiftSpelling
        return spelling == "String?" || spelling == "URL?"
    }
    // Positional rules gate index 0 unconditionally on these owners.
    if (owner == "FileManager" || owner == "URLSession"), optionalPathish(0) {
        return true
    }
    for (i, label) in argLabels.enumerated() where optionalPathish(i) {
        if pathStringLabelsRead.contains(label) || pathStringLabelsWrite.contains(label)
            || urlLabelsRead.contains(label) || urlLabelsWrite.contains(label)
        {
            return true
        }
    }
    return false
}

extension GateKind {
    /// True if this kind expresses a write-side operation. Used by
    /// the label scan to decide whether a `to:`-shaped URL arg
    /// keeps the receiver-default intent or upgrades to fsWrite.
    var isWrite: Bool {
        switch self {
        case .fsWrite, .fsDelete: return true
        case .fsRead, .network, .networkRequest: return false
        }
    }
}

/// Receiver-type spellings whose every bridge entry must short-
/// circuit with `try denyProcessIfSandboxed()` before doing any host
/// work. Used for `Foundation.Process` — it spawns a real OS
/// subprocess that escapes every host gate (path, network, identity),
/// so the policy is "denied entirely whenever a sandbox is active".
/// Embedders that want subprocess execution under a sandbox bind
/// SwiftBash's virtual-process table instead.
let denyWhenSandboxedReceivers: Set<String> = ["Process"]

/// Render the deny-when-sandboxed prologue. Wraps the synchronous
/// `denyProcessIfSandboxed()` throw in a `do/catch` that re-raises as
/// a `UserThrowSignal` — same shape as the path/URL gates — so
/// script-side `do/catch` blocks can pattern-match the typed denial
/// instead of seeing it as an opaque host-side error.
func denyPrologueLines(indent: String) -> [String] {
    return [
        "\(indent)do {",
        "\(indent)    try denyProcessIfSandboxed()",
        "\(indent)} catch {",
        "\(indent)    throw UserThrowSignal(value: .opaque(typeName: \"Error\", value: error))",
        "\(indent)}",
    ]
}

/// Identity-leaking property reads on `ProcessInfo` / `Bundle` /
/// `FileManager` get redirected to the bound shell's `HostInfo` /
/// `Environment` / `scriptName`. Returns the substitute call
/// expression (a string that produces a Swift value of the same
/// declared type) when the receiver/member match, or `nil` to leave
/// the bridge untouched.
///
/// The redirected expressions are top-level helpers from
/// `HostHooks.swift` — `hostUserName()`, `hostEnvironment()`, etc.
/// — that read `ShellKit.Shell.current` directly. Standalone
/// (`swift-script` CLI without an embedder) the helpers see
/// `Shell.processDefault` which mirrors the real OS values, so the
/// binary's behaviour is unchanged.
func redirectedPropertyCall(receiver: String, member: String) -> String? {
    switch (receiver, member) {
    case ("ProcessInfo", "userName"):           return "hostUserName()"
    case ("ProcessInfo", "fullUserName"):       return "hostFullUserName()"
    case ("ProcessInfo", "hostName"):           return "hostNameOverride()"
    case ("ProcessInfo", "processIdentifier"):  return "hostProcessIdentifier()"
    case ("ProcessInfo", "processName"):        return "hostProcessName()"
    case ("ProcessInfo", "environment"):        return "hostEnvironment()"
    case ("ProcessInfo", "arguments"):          return "hostProcessArguments()"
    // FileManager.currentDirectoryPath is the shell's logical cwd —
    // route through the bound environment so `cd /foo` from a
    // bash script is observable from a SwiftScript script in the
    // same Shell.
    case ("FileManager", "currentDirectoryPath"):
        return "ShellKit.Shell.current.environment.workingDirectory"
    // FileManager.temporaryDirectory reports the bound sandbox's
    // temp region, folded back to its script-visible spelling
    // (`/tmp` under a path-mapped sandbox) — never the host's
    // shared temp root. Standalone, `Shell.temporaryDirectory`
    // falls through to the platform temp dir and `displayPath`
    // is the identity, so the CLI behaviour is unchanged.
    case ("FileManager", "temporaryDirectory"):
        return "URL(fileURLWithPath: ShellKit.Shell.displayPath(for: ShellKit.Shell.temporaryDirectory), isDirectory: true)"
    default:
        return nil
    }
}

/// Receivers whose `String`/`URL`-returning members echo filesystem
/// paths back to the script (`destinationOfSymbolicLink`,
/// `Bundle.bundlePath`, `Bundle.url(forResource:…)`, …). Their
/// returns fold through `Shell.displayPath(for:)` so a path-mapped
/// sandbox's host layout never leaks into script-visible values —
/// and so a script can feed the answer straight back into a gated
/// call (which treats script text as virtual spelling). Non-path
/// strings on these receivers (`bundleIdentifier`, `displayName`)
/// pass through `displayPath` untouched: it only rewrites paths that
/// land under a mount's host root.
let displayFoldReceivers: Set<String> = ["FileManager", "Bundle"]

/// Wrap a `String`/`URL` return's box template so the value folds
/// through the bound shell's mapping before the script sees it.
/// Returns `nil` for non-path-shaped return types (leave unchanged).
func displayFoldedReturn(_ type: BridgedType) -> BridgedType? {
    switch type.swiftSpelling {
    case "String":
        return BridgedType(
            swiftSpelling: type.swiftSpelling,
            unboxTemplate: type.unboxTemplate,
            boxTemplate: ".string(ShellKit.Shell.displayPath(for: %@))")
    case "URL":
        return BridgedType(
            swiftSpelling: type.swiftSpelling,
            unboxTemplate: type.unboxTemplate,
            boxTemplate: "boxOpaque(URL(fileURLWithPath: ShellKit.Shell.displayPath(for: %@)), typeName: \"URL\")")
    default:
        return nil
    }
}

/// Render the prologue lines that bind the gated args to local names
/// and call the authorizer. Returns `(prologue, callExprRewriter)`
/// — the rewriter takes the original `unboxedCallArgs` string and
/// substitutes the bound names in for the gated positions.
func renderGates(
    _ directives: [GateDirective],
    sig: ResolvedSignature,
    indent: String
) -> (prologue: [String], callArgs: String, anyAsync: Bool) {
    guard !directives.isEmpty else {
        return ([], unboxedCallArgs(for: sig), false)
    }
    var prologue: [String] = []
    let directivesByIndex: [Int: GateDirective] =
        Dictionary(uniqueKeysWithValues: directives.map { ($0.argIndex, $0) })
    // Bind each gated arg to its bound name. Non-gated args are left
    // inline in the call args (built below).
    for d in directives {
        let unbox: String
        switch d.argSwiftType {
        case "String":
            unbox = "try unboxString(args[\(d.argIndex)])"
        case "URL":
            unbox = "try unboxOpaque(args[\(d.argIndex)], as: URL.self, typeName: \"URL\")"
        case "URLRequest":
            unbox = "try unboxOpaque(args[\(d.argIndex)], as: URLRequest.self, typeName: \"URLRequest\")"
        default:
            // Should be rejected by `gates(...)` above.
            unbox = "try unboxString(args[\(d.argIndex)])"
        }
        // Filesystem gates rebind the arg to the resolved host form
        // `authorizePath` returns — translated through the bound
        // sandbox's `PathMapping` — so the Foundation call consumes
        // exactly the path that was authorized. Binding as `var` and
        // assigning the return is what keeps check and I/O on the
        // same path; authorizing one spelling and touching another
        // is a sandbox escape. Network gates keep a `let`: the URL
        // is checked, never rewritten.
        let rebindsToAuthorized: Bool
        switch d.kind {
        case .fsRead, .fsWrite, .fsDelete: rebindsToAuthorized = true
        case .network, .networkRequest: rebindsToAuthorized = false
        }
        prologue.append("\(indent)\(rebindsToAuthorized ? "var" : "let") \(d.boundName) = \(unbox)")
        // Wrap the authorize call in a do/catch that re-throws the
        // sandbox denial (or any other gate error) as a
        // `UserThrowSignal`. Without the wrap, Foundation-side
        // errors like `Sandbox.Denial` propagate as raw Swift errors
        // — script-side `do { … } catch { }` can't see them, and
        // hosts get an opaque error rather than the typed thrown
        // value the rest of the bridge ABI uses.
        let authorizeCall: String
        switch d.kind {
        case .fsRead:
            authorizeCall = "\(d.boundName) = try await authorizePath(\(d.boundName), for: .read)"
        case .fsWrite:
            authorizeCall = "\(d.boundName) = try await authorizePath(\(d.boundName), for: .write)"
        case .fsDelete:
            authorizeCall = "\(d.boundName) = try await authorizePath(\(d.boundName), for: .delete)"
        case .network:
            // Network gate is `URL`-only — `String` URLs are out of
            // scope here (no async URL parser available); embedders
            // who care about that path can layer their own check.
            if d.argSwiftType == "URL" {
                authorizeCall = "try await authorizeURL(\(d.boundName))"
            } else {
                continue
            }
        case .networkRequest:
            // URLRequest carries the URL + method inline. A request
            // built from a relative URL has `.url == nil`; we treat
            // that as an unauthorisable empty-URL (the network
            // policy will deny it explicitly rather than silently
            // skipping the gate).
            authorizeCall = "try await authorizeURL(\(d.boundName).url ?? URL(fileURLWithPath: \"\"), method: \(d.boundName).httpMethod ?? \"GET\")"
        }
        prologue.append("\(indent)do {")
        prologue.append("\(indent)    \(authorizeCall)")
        prologue.append("\(indent)} catch {")
        prologue.append("\(indent)    throw UserThrowSignal(value: .opaque(typeName: \"Error\", value: error))")
        prologue.append("\(indent)}")
    }
    // Rebuild the call-args string: gated positions use the bound
    // name, ungated positions keep their inline `try unbox…`.
    let unboxed = sig.parameters.enumerated().map { (i, p) -> String in
        if let d = directivesByIndex[i] {
            return d.boundName
        }
        return render(p.type.unboxTemplate, "args[\(i)]")
    }
    let callArgs = zip(sig.parameters, unboxed)
        .map { (p, u) in (p.label == "_" ? "" : "\(p.label): ") + u }
        .joined(separator: ", ")
    return (prologue, callArgs, true)
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
    /// are emitted directly as a one-line dict entry. `var` so the
    /// overload emitter can re-render the same body under its
    /// bare-key alias.
    var registerLine: String
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
    /// Extra body lines emitted between the receiver unbox and the
    /// call expression. Used by the sandbox/network gating policy
    /// (see `gates(...)` and `renderGates(...)`) to bind path args
    /// and call `authorizePath` / `authorizeURL` before touching
    /// disk or the network.
    var prologue: [String] = []
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
    for line in c.prologue {
        bodyLines.append(line)
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
    for line in c.prologue {
        bodyLines.append(line)
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
/// introduced after our deployment target on any of the bridged
/// Apple platforms. The deployment targets live in `Package.swift`
/// (today: macOS 13 / iOS 16 / tvOS 16 / watchOS 9 — the SwiftBash
/// floor); we bake them in here to keep the generator self-
/// contained.
///
/// All four platform floors are checked independently — a symbol
/// introduced in iOS 16.1 on top of a macOS 13.0 conformance still
/// fails to link on iOS 16.0, so the iOS check has to fire even
/// when the macOS check passes.
///
/// Lowering any of these skips any Foundation symbol whose
/// `introduced` major version is higher than the floor, so the
/// generated bridges link cleanly on every platform SwiftBash
/// supports. The scl oracle continues to gate Apple-only entries
/// behind `#if canImport(Darwin)` independently.
let deploymentMacOSMajor = 13
let deploymentMacOSMinor = 0
let deploymentIOSMajor = 16
let deploymentIOSMinor = 0
let deploymentTVOSMajor = 16
let deploymentTVOSMinor = 0
let deploymentWatchOSMajor = 9
let deploymentWatchOSMinor = 0

/// `(major, minor)` deployment floor for `domain`, or `nil` for
/// non-platform domains (`*`, `swift`).
private func deploymentFloor(forDomain domain: String) -> (Int, Int)? {
    switch domain {
    case "macOS":   return (deploymentMacOSMajor,   deploymentMacOSMinor)
    case "iOS":     return (deploymentIOSMajor,     deploymentIOSMinor)
    case "tvOS":    return (deploymentTVOSMajor,    deploymentTVOSMinor)
    case "watchOS": return (deploymentWatchOSMajor, deploymentWatchOSMinor)
    default:        return nil
    }
}

func isDeprecated(_ sym: SymbolGraph.Symbol) -> Bool {
    guard let avail = sym.availability else { return false }
    for a in avail {
        if a.isUnconditionallyDeprecated == true { return true }
        if a.isUnconditionallyUnavailable == true { return true }
        if a.obsoleted != nil { return true }
        // "Soft-deprecated" symbols carry `deprecated: { major: 100000 }` —
        // a sentinel meaning "we'd like you to migrate, but the symbol
        // still compiles and runs". Only treat as deprecated if the
        // version is below the sentinel. Per-platform-domain entries
        // gate on the deployment target so a future-platform
        // deprecation doesn't pre-emptively trip when building for an
        // older OS.
        if let dep = a.deprecated?.major {
            let softSentinel = 100000
            if dep < softSentinel {
                if let floor = deploymentFloor(forDomain: a.domain ?? "") {
                    if dep <= floor.0 { return true }
                } else {
                    // `swift`, `*`, and unknown domains — if the
                    // version says deprecated, swiftc emits the
                    // warning, so skip the bridge.
                    return true
                }
            }
        }
        if let floor = deploymentFloor(forDomain: a.domain ?? ""),
           let major = a.introduced?.major
        {
            if major > floor.0 { return true }
            if major == floor.0,
               let minor = a.introduced?.minor,
               minor > floor.1
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
    /// Available on macOS / Linux / Windows / Android but NOT on the
    /// iOS family (iOS, tvOS, watchOS, visionOS). Currently just
    /// `Foundation.Process` — the scl oracle classifies it
    /// cross-platform because Linux Foundation has it, but Apple's
    /// non-macOS overlays mark it `@available(*, unavailable)`.
    case nonIOSOnly
}

/// Type spellings that require the non-iOS-family guard. The scl
/// oracle classifies these as cross-platform (they exist on at least
/// one non-Apple platform), but Apple's iOS-family Foundation
/// overlays mark them unavailable, so a plain cross-platform emit
/// fails to compile for iOS Simulator. Wrap their per-type bridge
/// file and any runtime-body emits with `#if !os(iOS) && !os(tvOS)
/// && !os(watchOS) && !os(visionOS)`.
let nonIOSOnlyTypes: Set<String> = ["Process"]
let nonIOSGuardCondition = "!os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)"

struct EmitEntry {
    let symbolPath: String   // "sqrt(_:)" or "String.foo(...)"
    let group: EmitGroup
    let bucket: EmitBucket
    let code: String
    let platform: Platform
}

/// Parse a bridge entry's display key (e.g. `"var URL.path: String"` or
/// `"init URL(_:)"` or `"static func URL.allocate()"`) into a
/// `(typeName, memberName)` pair. Returns `("", funcName)` for free
/// functions with no owning type. Used to look the entry up in the
/// scl oracle for cross-platform classification.
func ownerAndMember(forBridgeKey key: String) -> (String, String)? {
    // Normalize `"static let X.foo"` and similar prefixes — the trailing
    // tokens are what matter.
    var s = key
    for prefix in ["static let ", "static var ", "static func ",
                   "mutating func ", "set var ", "subscript ",
                   "let ", "var ", "func ", "init "] {
        if s.hasPrefix(prefix) { s.removeFirst(prefix.count); break }
    }
    // For `init URL(_:)` form: the type name precedes the `(`.
    if let openParen = s.firstIndex(of: "("), key.hasPrefix("init ") {
        return (String(s[..<openParen]), "init")
    }
    // Strip generic parameter list (`<T: Encodable>`) before any
    // colon-based stripping — the `:` inside the generic constraint
    // would otherwise truncate the member name to `encode<T`.
    if let openAngle = s.firstIndex(of: "<"),
       let closeAngle = s.firstIndex(of: ">"),
       openAngle < closeAngle
    {
        s = String(s[..<openAngle]) + String(s[s.index(after: closeAngle)...])
    }
    // Strip trailing `: ReturnType` and trailing `()` argument lists.
    if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
    if let openParen = s.firstIndex(of: "(") { s = String(s[..<openParen]) }
    s = s.trimmingCharacters(in: .whitespaces)
    // Split on the LAST `.` so nested types like `String.Index.foo`
    // resolve owner=`String.Index`, member=`foo`. No dot at all means
    // a free function with no owning type — return empty owner so the
    // oracle's free-function set gets consulted.
    guard let lastDot = s.lastIndex(of: ".") else { return ("", s) }
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
    guard let (owner, member) = ownerAndMember(forBridgeKey: key) else {
        return sclOracle == nil ? .crossPlatform : .crossPlatform
    }
    if nonIOSOnlyTypes.contains(owner) { return .nonIOSOnly }
    guard let oracle = sclOracle else { return .crossPlatform }
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
    // Blocklist applies to type promotion too — entries like
    // `Date.HTTPFormatStyle` (Apple-only nested struct) need to be
    // skipped here, not just at the per-member emit step, otherwise
    // the type gets a bridge file and aggregator entry that
    // reference a type the Linux build can't see.
    guard !blocklist.contains(typeName) else { continue }
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

/// Type spellings classified Apple-only by the scl oracle. The whole
/// per-type bridge file gets wrapped in `#if canImport(Darwin)` so
/// Linux/Windows skip referencing the type at all.
nonisolated(unsafe) var appleOnlyTypes: Set<String> = []
if let oracle = sclOracle {
    for (_, bridge) in bridgedTypes {
        let spelling = bridge.swiftSpelling
        // Stdlib types and primitive bridges are always present.
        if stdlibCrossPlatformOwners.contains(spelling) { continue }
        // `nonIOSOnlyTypes` get their own guard wrap; never classify
        // them Apple-only or the non-Apple platforms (Linux/Windows/
        // Android) lose them.
        if nonIOSOnlyTypes.contains(spelling) { continue }
        if !oracle.isTypeCrossPlatform(spelling) {
            appleOnlyTypes.insert(spelling)
        }
    }
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
        guard let fullSig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value parameter or return"; continue
        }
        let methodName = sym.names.title.split(separator: "(").first.map(String.init) ?? sym.names.title
        // One entry per omittable defaulted suffix, shortest first,
        // so `session.data(from: url)` works even though the symbol
        // spells `data(from:delegate:)`.
        for sig in signatureVariants(fullSig) {
            let methodLabels = sig.parameters.map(\.label)
            // Optional path-shaped args can't be rewritten by the gate —
            // skipping beats shipping an ungated IO door.
            if hasUngatablePathParam(
                receiver: receiverTypeName, initFor: nil,
                argLabels: methodLabels, signature: sig)
            {
                skippedReasons[path] = "optional path-shaped arg cannot be gated"
                continue
            }
            // Overloads are keyed by their argument labels (after
            // default-arg drops), so `URLSession.data(from:)` and
            // `URLSession.data(for:)` coexist. The runtime tries the
            // label-keyed entry first and falls back to the bare-key
            // alias registered for the first (fewest-args) overload.
            let labelKeyText = methodLabels.map { "\($0):" }.joined()
            let key = "method:\(receiverTypeName).\(methodName)(\(labelKeyText))"
            if !claim(key, clashLabel: "\(receiverTypeName).\(methodName)(\(labelKeyText))") { continue }
            let recvUnbox = render(recvType.unboxTemplate, "receiver")
            let methodGates = gates(
                forReceiver: receiverTypeName,
                methodName: methodName,
                argLabels: methodLabels,
                signature: sig)
            var methodGated = renderGates(methodGates, sig: sig, indent: "        ")
            // Process: every method is denied when a sandbox is bound.
            // Inject the deny check in front of any other gate prologue
            // so even a sandbox-passing arg never reaches the
            // subprocess-spawning Foundation API.
            if denyWhenSandboxedReceivers.contains(receiverTypeName) {
                methodGated.prologue.insert(contentsOf: denyPrologueLines(indent: "        "), at: 0)
            }
            // Path-echoing returns fold to the script-visible spelling.
            var methodReturn = sig.returnType
            if displayFoldReceivers.contains(receiverTypeName),
               let ret = methodReturn, let folded = displayFoldedReturn(ret)
            {
                methodReturn = folded
            }
            var methodConfig = EmitConfig(
                registerLine: "\"func \(receiverTypeName).\(methodName)(\(labelKeyText))\": .method",
                closureParams: "receiver, args",
                arity: sig.parameters.count,
                recvUnboxLine: "let recv: \(recvType.swiftSpelling) = \(recvUnbox)",
                callExpr: "recv.\(methodName)(\(methodGated.callArgs))",
                errorPrefix: "\(receiverTypeName).\(methodName)",
                returnType: methodReturn,
                isOptional: sig.returnIsOptional,
                isThrowing: isThrowing(sym),
                // Sandbox/network gates use `await` on the bound shell's
                // `Sandbox.authorize(_:)`, so any gated bridge becomes
                // async even if the underlying Swift call is sync.
                isAsync: isAsync(sym) || methodGated.anyAsync,
                tupleElements: sig.returnTupleElements,
                prologue: methodGated.prologue
            )
            record(key, bucket: .type(receiverTypeName), code: renderEmit(methodConfig))
            // Bare-key alias for the first overload of each name: dispatch
            // sites that carry no labels (trailing-closure calls, the
            // FileManager sentinel fallback) resolve here. A zero-arg
            // overload's label key IS the bare key (its claim below
            // matches), so fewest-args-first symbol ordering hands the
            // alias to the simplest overload.
            let bareClaim = "method:\(receiverTypeName).\(methodName)()"
            if !labelKeyText.isEmpty, !registeredKeys.contains(bareClaim) {
                methodConfig.registerLine = "\"func \(receiverTypeName).\(methodName)()\": .method"
                record(bareClaim, bucket: .type(receiverTypeName), code: renderEmit(methodConfig))
            }
        }

    case "swift.method" where (2...3).contains(sym.pathComponents.count) &&
                              isMutating(sym) &&
                              !isDeprecated(sym) &&
                              !isGeneric(sym) &&
                              !isAsync(sym):
        // Mutating methods on value-typed opaque carriers
        // (`Data.append`, `URLRequest.setValue`) — the closure gets a
        // copy, mutates it, and hands back the fresh box for the
        // dispatcher to store into the receiver variable.
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard let recvType = bridgeableReceivers[receiverTypeName],
              recvType.unboxTemplate.contains("unboxOpaque")
        else {
            skippedReasons[path] = "mutating on non-opaque receiver"; continue
        }
        guard let fullSig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value parameter or return"; continue
        }
        let mutMethodName = sym.names.title.split(separator: "(").first.map(String.init) ?? sym.names.title
        for sig in signatureVariants(fullSig) {
            let mutLabels = sig.parameters.map(\.label)
            if hasUngatablePathParam(
                receiver: receiverTypeName, initFor: nil,
                argLabels: mutLabels, signature: sig)
            {
                skippedReasons[path] = "optional path-shaped arg cannot be gated"
                continue
            }
            // Result shapes: Void, plain T, and T? with a non-throwing
            // box. Tuples and throwing boxes stay out of scope.
            if !sig.returnTupleElements.isEmpty { continue }
            if let ret = sig.returnType, sig.returnIsOptional,
               ret.boxTemplate.contains("try ") { continue }
            let labelText = mutLabels.map { "\($0):" }.joined()
            let key = "mutating-method:\(receiverTypeName).\(mutMethodName)(\(labelText))"
            if !claim(key, clashLabel: "\(receiverTypeName).\(mutMethodName)(\(labelText))") { continue }
            let mutGates = gates(
                forReceiver: receiverTypeName,
                methodName: mutMethodName,
                argLabels: mutLabels,
                signature: sig)
            let mutGated = renderGates(mutGates, sig: sig, indent: "        ")
            let prefix = (isThrowing(sym) ? "try " : "")
            let callLine: String
            let resultExpr: String
            if let ret = sig.returnType {
                callLine = "let _r = \(prefix)recv.\(mutMethodName)(\(mutGated.callArgs))"
                resultExpr = sig.returnIsOptional
                    ? ".optional(_r.map { \(render(ret.boxTemplate, "$0")) })"
                    : render(ret.boxTemplate, "_r")
            } else {
                callLine = "\(prefix)recv.\(mutMethodName)(\(mutGated.callArgs))"
                resultExpr = ".void"
            }
            let bodyCore = """
                    \(callLine)
                    return (\(resultExpr), boxOpaque(recv, typeName: "\(receiverTypeName)"))
            """
            let wrappedCore: String
            if isThrowing(sym) {
                wrappedCore = """
                        do {
                    \(bodyCore)
                        } catch {
                            throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
                        }
                """
            } else {
                wrappedCore = bodyCore
            }
            func mutatingEntry(keyed dictKey: String) -> String {
                var lines: [String] = []
                lines.append("    \"\(dictKey)\": .mutatingMethod { receiver, args in")
                lines.append("        guard args.count == \(sig.parameters.count) else {")
                lines.append("            throw RuntimeError.invalid(\"\(receiverTypeName).\(mutMethodName): expected \(sig.parameters.count) argument(s), got \\(args.count)\")")
                lines.append("        }")
                lines.append("        var recv: \(recvType.swiftSpelling) = \(render(recvType.unboxTemplate, "receiver"))")
                lines.append(contentsOf: mutGated.prologue)
                lines.append(wrappedCore)
                lines.append("    },")
                return lines.joined(separator: "\n")
            }
            record(key, bucket: .type(receiverTypeName),
                   code: mutatingEntry(keyed: "mutating func \(receiverTypeName).\(mutMethodName)(\(labelText))"))
            let bareClaim = "mutating-method:\(receiverTypeName).\(mutMethodName)()"
            if !labelText.isEmpty, !registeredKeys.contains(bareClaim) {
                record(bareClaim, bucket: .type(receiverTypeName),
                       code: mutatingEntry(keyed: "mutating func \(receiverTypeName).\(mutMethodName)()"))
            }
        }

    case "swift.init" where (2...3).contains(sym.pathComponents.count) && !isDeprecated(sym) && !isGeneric(sym) && !isAsync(sym):
        let rawReceiver = sym.pathComponents.dropLast().joined(separator: ".")
        let receiverTypeName = receiverAliases[rawReceiver] ?? rawReceiver
        guard let recvType = bridgeableReceivers[receiverTypeName] else {
            skippedReasons[path] = "unbridged init owner '\(rawReceiver)'"; continue
        }
        guard let fullSig = resolveSignature(sym) else {
            skippedReasons[path] = "non-value parameter or return"; continue
        }
        // `init?(…)` failability: in the fragment list, the `init`
        // keyword is followed by `?(…)` for failable variants.
        let df = sym.declarationFragments ?? []
        var failable = false
        for (i, frag) in df.enumerated() where frag.spelling == "init" {
            if i + 1 < df.count, df[i + 1].spelling.hasPrefix("?") { failable = true }
            break
        }
        // One entry per omittable defaulted suffix — inits dispatch
        // by exact label list, so `URLRequest(url:)` needs its own
        // key next to `URLRequest(url:timeoutInterval:)`.
        for sig in signatureVariants(fullSig) {
            let labels = sig.parameters.map(\.label)
            if hasUngatablePathParam(
                receiver: nil, initFor: receiverTypeName,
                argLabels: labels, signature: sig)
            {
                skippedReasons[path] = "optional path-shaped arg cannot be gated"
                continue
            }
            let labelKey = labels.joined(separator: ":")
            let key = "init:\(receiverTypeName)(\(labelKey))"
            if !claim(key, clashLabel: "\(receiverTypeName)(\(labelKey))") { continue }
            let labelDoc = labels.isEmpty ? "" : labels.map { "\($0):" }.joined()
            let initKey = "init \(receiverTypeName)(\(labelDoc))"
            // Inits like `String(contentsOfFile:)` and `Data(contentsOf:)`
            // hit disk; route them through `authorizePath` exactly like
            // a method on the same type.
            let initMethodName = labels.first
            let initGates = gates(
                forReceiver: nil,
                methodName: initMethodName,
                initFor: receiverTypeName,
                argLabels: labels,
                signature: sig)
            var initGated = renderGates(initGates, sig: sig, indent: "        ")
            // Process: even constructing a Process is denied under sandbox,
            // so a script can't capture an instance and pass it around.
            if denyWhenSandboxedReceivers.contains(receiverTypeName) {
                initGated.prologue.insert(contentsOf: denyPrologueLines(indent: "        "), at: 0)
            }
            record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
                registerLine: "\"\(initKey)\": .`init`",
                closureParams: "args",
                arity: sig.parameters.count,
                recvUnboxLine: nil,
                callExpr: "\(receiverTypeName)(\(initGated.callArgs))",
                errorPrefix: initKey,
                returnType: recvType,
                isOptional: failable,
                isThrowing: isThrowing(sym),
                isAsync: isAsync(sym) || initGated.anyAsync,
                tupleElements: [],
                prologue: initGated.prologue
            )))
        }

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
        // Identity-leaking ProcessInfo / Bundle properties get
        // redirected to the shell's `HostInfo` / `Environment` /
        // `scriptName` so a sandboxed embedder doesn't fingerprint
        // the host. Swap the call expression and drop the receiver
        // unbox where the redirect doesn't need it.
        let redirected = redirectedPropertyCall(
            receiver: receiverTypeName, member: memberName)
        // Process: every property read/write requires the deny check
        // up front so a sandboxed script can't inspect or set
        // `arguments`/`environment`/etc. on the way to a `.run()` call.
        var propPrologue: [String] = []
        if denyWhenSandboxedReceivers.contains(receiverTypeName) {
            propPrologue.append(contentsOf: denyPrologueLines(indent: "        "))
        }
        // Path-echoing property reads fold to the script-visible
        // spelling. Redirected properties already produce it.
        var propReturn = propType.bridge
        if redirected == nil,
           displayFoldReceivers.contains(receiverTypeName),
           let folded = displayFoldedReturn(propReturn)
        {
            propReturn = folded
        }
        record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
            registerLine: "\"var \(receiverTypeName).\(memberName): \(propTypeSpelling)\": .computed",
            closureParams: redirected != nil ? "_" : "receiver",
            arity: nil,
            recvUnboxLine: redirected != nil ? nil
                : "let recv: \(recvType.swiftSpelling) = \(recvUnbox)",
            callExpr: redirected ?? "recv.\(memberName)",
            errorPrefix: "\(receiverTypeName).\(memberName)",
            returnType: propReturn,
            isOptional: propType.isOptional,
            isThrowing: false,
            isAsync: false,
            tupleElements: [],
            prologue: propPrologue
        )))
        // For `var` properties on bridged types, emit a setter
        // alongside the getter. Class receivers mutate the reference
        // in place (`.setter`); struct receivers return a fresh box
        // for the l-value machinery to write back (`.structSetter`)
        // — that's what makes `request.httpMethod = "POST"` work.
        let isClassReceiver = bridgedClassTypeNames.contains(receiverTypeName)
        let isOpaqueStructReceiver = !isClassReceiver
            && recvType.unboxTemplate.contains("unboxOpaque")
        if isClassReceiver || isOpaqueStructReceiver,
           isVarMutable(sym)
        {
            // Optional properties (`Process.executableURL: URL?`)
            // unbox through the optional wrapper so scripts can
            // assign both a value and nil. `unwrapForSetter` peels a
            // wrapped Optional first — Foundation's IUO members
            // (`DateFormatter.timeZone`) take failable-init results
            // without an unwrap in stock Swift.
            let newValueBridge = propType.isOptional
                ? optionalParamBridge(of: propType.bridge)
                : propType.bridge
            let unboxNew = render(newValueBridge.unboxTemplate, "unwrapForSetter(newValue)")
            let setterDeny = denyWhenSandboxedReceivers.contains(receiverTypeName)
                ? denyPrologueLines(indent: "            ").joined(separator: "\n") + "\n"
                : ""
            let setterCode: String
            if isClassReceiver {
                setterCode = """
                        \"set var \(receiverTypeName).\(memberName): \(propTypeSpelling)\": .setter { receiver, newValue in
                \(setterDeny)            let recv: \(recvType.swiftSpelling) = \(recvUnbox)
                            recv.\(memberName) = \(unboxNew)
                        },
                """
            } else {
                setterCode = """
                        \"set var \(receiverTypeName).\(memberName): \(propTypeSpelling)\": .structSetter { receiver, newValue in
                \(setterDeny)            var recv: \(recvType.swiftSpelling) = \(recvUnbox)
                            recv.\(memberName) = \(unboxNew)
                            return boxOpaque(recv, typeName: "\(receiverTypeName)")
                        },
                """
            }
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
        // Throwing box templates (`UInt64.max` exceeds Int.max) can't
        // run inside the static dict initializer — and would throw at
        // registration anyway. Skip them.
        guard !propType.bridge.boxTemplate.contains("try ") else {
            skippedReasons[path] = "static value needs a throwing box"; continue
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
        let staticLabels = sig.parameters.map(\.label)
        // Static methods hit the SAME sandbox gates as instance
        // methods — `Bundle.path(forResource:ofType:inDirectory:)`
        // reads a directory the same way an instance door does.
        // Without this an ungated static path arg is a confinement
        // escape.
        if hasUngatablePathParam(
            receiver: receiverTypeName, initFor: nil,
            argLabels: staticLabels, signature: sig)
        {
            skippedReasons[path] = "optional path-shaped arg cannot be gated"; continue
        }
        let key = "static-method:\(receiverTypeName).\(methodName)"
        if !claim(key, clashLabel: "\(receiverTypeName).\(methodName)") { continue }
        let staticGates = gates(
            forReceiver: receiverTypeName,
            methodName: methodName,
            initFor: receiverTypeName,   // static factories gate like inits
            argLabels: staticLabels,
            signature: sig)
        var staticGated = renderGates(staticGates, sig: sig, indent: "        ")
        // Process: static factories (e.g. `Process.launchedProcess`)
        // need the same deny check as instance methods/inits.
        if denyWhenSandboxedReceivers.contains(receiverTypeName) {
            staticGated.prologue.insert(contentsOf: denyPrologueLines(indent: "        "), at: 0)
        }
        record(key, bucket: .type(receiverTypeName), code: renderEmit(EmitConfig(
            registerLine: "\"static func \(receiverTypeName).\(methodName)()\": .staticMethod",
            closureParams: "args",
            arity: sig.parameters.count,
            recvUnboxLine: nil,
            callExpr: "\(receiverTypeName).\(methodName)(\(staticGated.callArgs))",
            errorPrefix: "\(receiverTypeName).\(methodName)",
            returnType: sig.returnType,
            isOptional: sig.returnIsOptional,
            isThrowing: isThrowing(sym),
            isAsync: isAsync(sym) || staticGated.anyAsync,
            tupleElements: sig.returnTupleElements,
            prologue: staticGated.prologue
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
        // Same trick as `record()`: claim keys carry an internal
        // prefix (`"generic-method:func JSONEncoder.encode<…>"`) that
        // doesn't match anything in scl. Pull the user-facing bridge
        // key out of the emitted code so the classifier sees
        // `"func JSONEncoder.encode<…>"` and can resolve to the
        // matching scl member.
        let bridgeKey = extractBridgeKey(fromCode: code) ?? claimKey
        emitted.append(EmitEntry(
            symbolPath: path, group: emitGroup, bucket: bucket, code: code,
            platform: platform(forBridgeKey: bridgeKey)
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

// MARK: - Inherited no-arg init pass
//
// Allowlisted classes that inherit `init()` from NSObject
// (DateFormatter, ISO8601DateFormatter, Pipe) have no `init` symbol
// of their own in the graph, so the main pass never emits one and
// `DateFormatter()` fails with "cannot find in scope". Synthesise
// the no-arg init for the classes verified to have a public
// parameterless initializer.
let synthesizedNoArgInits: [String] = [
    "DateFormatter", "ISO8601DateFormatter", "Pipe",
]
for typeName in synthesizedNoArgInits {
    let claimKey = "init:\(typeName)()"
    if registeredKeys.contains(claimKey) { continue }
    guard bridgedClassTypeNames.contains(typeName) else { continue }
    let code = """
            \"init \(typeName)()\": .`init` { args in
                guard args.isEmpty else {
                    throw RuntimeError.invalid("init \(typeName)(): expected 0 argument(s), got \\(args.count)")
                }
                return boxOpaque(\(typeName)(), typeName: "\(typeName)")
            },
    """
    emitted.append(EmitEntry(
        symbolPath: "\(typeName).init()",
        group: .foundation, bucket: .type(typeName), code: code,
        platform: platform(forBridgeKey: "init \(typeName)()")
    ))
    registeredKeys.insert(claimKey)
}

// Types whose `Comparable` conformance arrives after our deployment
// floor — the conformance declaration itself carries `@available(macOS X)`
// and the symbol-graph relationship metadata doesn't surface that
// gating, so we maintain it by hand here. Update when the floor moves.
//
// Bake-by-bake: whenever a regen at the current floor fails with
// "conformance of X to Comparable is only available in macOS Y or
// newer", add the spelling here. The fallback (`Equatable`-only)
// still lets scripts compare with `==`; ordering becomes a no-op.
let comparableUnavailableAtFloor: Set<String> = [
    // UUID gets `Comparable` at macOS 14 / iOS 17 (FB-IDs in
    // Apple's release notes for Foundation 2023).
    "UUID",
]

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
        && !comparableUnavailableAtFloor.contains(bridge.swiftSpelling)
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
    // Comparator references the type itself. Reference-type Foundation
    // classes from the bridgeable allowlist (FileManager, ProcessInfo,
    // URLSession, …) are NSObject-Equatable on Apple but not value-
    // comparable on Linux/scl (they're typealiased to NSXxx classes
    // without an Equatable conformance the auto-comparator can use).
    // Force those to Apple-only regardless of scl type-presence.
    let comparatorPlatform: Platform
    if nonIOSOnlyTypes.contains(typeName) {
        comparatorPlatform = .nonIOSOnly
    } else if bridgeableTypeAllowlist.contains(typeName)
        && bridgedClassTypeNames.contains(typeName)
    {
        comparatorPlatform = .appleOnly
    } else {
        comparatorPlatform = (sclOracle?.isTypeCrossPlatform(typeName) ?? true)
            ? .crossPlatform : .appleOnly
    }
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
    /// When true, the type itself doesn't exist on the cross-platform
    /// side (e.g. `DateComponentsFormatter`, `MeasurementFormatter`
    /// — both `@available(*, unavailable)` in scl). The whole per-type
    /// file gets wrapped in `#if canImport(Darwin)` and the manifest's
    /// reference to it is gated too.
    var typeIsAppleOnly: Bool = false
    /// When true, the type is unavailable on the iOS family (iOS,
    /// tvOS, watchOS, visionOS) but exists on macOS / Linux / Windows
    /// / Android. The whole per-type file gets wrapped in
    /// `#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)`.
    /// Mutually exclusive with `typeIsAppleOnly`.
    var typeIsNonIOSOnly: Bool = false
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
    // Whole-file gating: when the type itself is Apple-only every
    // entry is too, so wrap the whole `extension { … }` block. The
    // dict still exists on Linux as an empty `[:]` so the manifest's
    // reference doesn't dangle.
    if entries.typeIsAppleOnly {
        let dictName = staticLetName(for: typeName)
        let allEntries = (entries.crossPlatform + entries.appleOnly)
            .joined(separator: "\n")
        let body = allEntries.isEmpty ? "        // (no entries)" : allEntries
        return """
        \(autogenBanner)import Foundation
        import ShellKit
        #if canImport(FoundationNetworking)
        import FoundationNetworking
        #endif

        #if canImport(Darwin)
        extension \(namespace) {
            nonisolated(unsafe) static let \(dictName): [String: Bridge] = [
        \(body)
            ]
        }
        #else
        extension \(namespace) {
            nonisolated(unsafe) static let \(dictName): [String: Bridge] = [:]
        }
        #endif

        """
    }
    if entries.typeIsNonIOSOnly {
        // Available on macOS / Linux / Windows / Android but not on
        // the iOS family — emit the dict under the non-iOS guard and
        // a `[:]` stub elsewhere so the manifest's reference still
        // resolves on every platform.
        let dictName = staticLetName(for: typeName)
        let allEntries = (entries.crossPlatform + entries.appleOnly)
            .joined(separator: "\n")
        let body = allEntries.isEmpty ? "        // (no entries)" : allEntries
        return """
        \(autogenBanner)import Foundation
        import ShellKit
        #if canImport(FoundationNetworking)
        import FoundationNetworking
        #endif

        #if \(nonIOSGuardCondition)
        extension \(namespace) {
            nonisolated(unsafe) static let \(dictName): [String: Bridge] = [
        \(body)
            ]
        }
        #else
        extension \(namespace) {
            nonisolated(unsafe) static let \(dictName): [String: Bridge] = [:]
        }
        #endif

        """
    }
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
            import ShellKit
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
        import ShellKit
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
        import ShellKit
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
        import ShellKit
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
        case .nonIOSOnly:    current.crossPlatform.append(entry.code)
        }
        bodies[name] = current
    }
    // Stamp `typeIsAppleOnly` on every type the scl oracle classified
    // as not-cross-platform. Used by `renderPerTypeFile` to wrap the
    // whole `extension { … }` block in `#if canImport(Darwin)`.
    for name in order where appleOnlyTypes.contains(name) {
        bodies[name]?.typeIsAppleOnly = true
    }
    // Same for the non-iOS-family wrap. Entries are folded into
    // `crossPlatform` above (the per-type file uses a single dict
    // literal under the file-level guard), so `appleOnly` stays
    // empty and the renderer takes the literal-dict path.
    for name in order where nonIOSOnlyTypes.contains(name) {
        bodies[name]?.typeIsNonIOSOnly = true
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
        case .nonIOSOnly:
            return "#if \(nonIOSGuardCondition)\n\(entry.code)\n#endif"
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
