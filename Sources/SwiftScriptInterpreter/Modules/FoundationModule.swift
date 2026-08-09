import Foundation
import ShellKit

/// Everything that `swiftc` requires `import Foundation` (or `Darwin` /
/// `Glibc`) for: free C math globals, `String(format:)`, `String`'s
/// file-I/O initializers, `FileManager` and friends.
///
/// Registered lazily — `Interpreter.processImport("Foundation")` triggers
/// `register(into:)` on first import. Without the import, the names
/// aren't bound and lookups fail with `cannot find 'X' in scope` — same
/// caret-style diagnostic `swiftc` emits.
public struct FoundationModule: BuiltinModule {
    public let name = "Foundation"
    public init() {}

    public func register(into i: Interpreter) {
        registerCMathGlobals(into: i)
        registerCMathConstants(into: i)
        registerStringMethods(into: i)
        registerDataSubscripts(into: i)
        // Auto-generated Foundation bridges. Regenerate via
        //   bash Tools/regen-foundation-bridge.sh
        //
        // The symbol graph is harvested from Apple's Foundation, then
        // each entry is classified against an extract of swift-
        // corelibs-foundation (`Resources/foundation-symbols-scl.txt`):
        // entries that exist on both sides are emitted unconditionally,
        // entries that only exist on Apple are wrapped in
        // `#if canImport(Darwin)` blocks. The same per-type files
        // therefore work on macOS, iOS, Linux, and Windows.
        registerGenerated(into: i)
        // Must run AFTER registerGenerated — these replace generated
        // entries whose host-process answers would leak the embedder's
        // layout into a virtualised shell.
        registerShellVirtualizationOverrides(into: i)
        // Also after registerGenerated: hand-written dual-type
        // dispatchers that must outrank narrower generated overloads
        // sharing the same labels.
        i.bridges["func String.components()"] = Self.stringComponentsBridge
        i.bridges["func String.components(separatedBy:)"] = Self.stringComponentsBridge
        registerStringSearchIdioms(into: i)
        registerProcessStandardStreams(into: i)
        registerNumericConversions(into: i)
        registerDataAppend(into: i)
    }

    // MARK: - Numeric-conversion inits

    /// `UInt8(3)`, `Int32(7)`, `Float(2.5)` — the fixed-width and
    /// Float value-conversion inits. The generated `init T(_:)` binds
    /// the failable `LosslessStringConvertible` (String) overload, so
    /// a numeric arg hit "expected String". This dispatcher owns the
    /// bare `init T(_:)` key and routes on the runtime arg: a numeric
    /// value converts (range-checked, non-optional like stock), a
    /// String stays the failable string parse.
    private func registerNumericConversions(into i: Interpreter) {
        func convert(_ v: Value, into spelling: String) throws -> Value {
            switch spelling {
            case "Int8": return .int(Int(try toInt8(v)))
            case "Int16": return .int(Int(try toInt16(v)))
            case "Int32": return .int(Int(try toInt32(v)))
            case "Int64": return .int(Int(try toInt64(v)))
            case "UInt8": return .int(Int(try toUInt8(v)))
            case "UInt16": return .int(Int(try toUInt16(v)))
            case "UInt32": return .int(Int(try toUInt32(v)))
            case "UInt64": return try boxUnsignedAsInt(try toUInt64(v))
            case "UInt": return try boxUnsignedAsInt(try toUInt(v))
            case "Float": return .double(Double(try toFloat(v)))
            default: throw RuntimeError.invalid("\(spelling): not a numeric type")
            }
        }
        for spelling in ["Int8", "Int16", "Int32", "Int64",
                         "UInt8", "UInt16", "UInt32", "UInt64", "UInt", "Float"] {
            i.bridges["init \(spelling)(_:)"] = .`init` { args in
                guard args.count == 1 else {
                    throw RuntimeError.invalid("\(spelling)(_:): expected 1 argument, got \(args.count)")
                }
                switch args[0] {
                case .int, .double:
                    // Numeric conversion — non-optional, throws on overflow.
                    return try convert(args[0], into: spelling)
                case .string(let s):
                    // Failable string parse — `UInt8("42")` is `UInt8?`.
                    switch spelling {
                    case "Int8": return .optional(Int8(s).map { .int(Int($0)) } ?? nil)
                    case "Int16": return .optional(Int16(s).map { .int(Int($0)) } ?? nil)
                    case "Int32": return .optional(Int32(s).map { .int(Int($0)) } ?? nil)
                    case "Int64": return .optional(Int64(s).map { .int(Int($0)) } ?? nil)
                    case "UInt8": return .optional(UInt8(s).map { .int(Int($0)) } ?? nil)
                    case "UInt16": return .optional(UInt16(s).map { .int(Int($0)) } ?? nil)
                    case "UInt32": return .optional(UInt32(s).map { .int(Int($0)) } ?? nil)
                    case "UInt64": return .optional((UInt64(s).flatMap { Int(exactly: $0) }).map { .int($0) } ?? nil)
                    case "UInt": return .optional((UInt(s).flatMap { Int(exactly: $0) }).map { .int($0) } ?? nil)
                    case "Float": return .optional(Float(s).map { .double(Double($0)) } ?? nil)
                    default: return .optional(nil)
                    }
                default:
                    throw RuntimeError.invalid(
                        "\(spelling)(_:): expected a number or String, got \(typeName(args[0]))")
                }
            }
        }
    }

    // MARK: - Data.append (byte + Data overloads)

    /// `data.append(3)` (UInt8) and `data.append(otherData)` share
    /// the label key `mutating func Data.append(_:)`, so the
    /// generated single-type entry can only unbox one. This
    /// dispatcher owns the key and routes on the arg's runtime type.
    private func registerDataAppend(into i: Interpreter) {
        let body: Bridge = .mutatingMethod { receiver, args in
            var data: Data = try unboxOpaque(receiver, as: Data.self, typeName: "Data")
            guard args.count == 1 else {
                throw RuntimeError.invalid("Data.append: expected 1 argument, got \(args.count)")
            }
            switch args[0] {
            case .int(let byte):
                guard (0...255).contains(byte) else {
                    throw RuntimeError.invalid("Data.append: byte value \(byte) out of UInt8 range")
                }
                data.append(UInt8(byte))
            case .opaque(typeName: "Data", let any):
                guard let other = any as? Data else {
                    throw RuntimeError.invalid("Data.append: malformed Data")
                }
                data.append(other)
            case .array(let xs):
                var bytes: [UInt8] = []
                for x in xs {
                    guard case .int(let b) = x, (0...255).contains(b) else {
                        throw RuntimeError.invalid("Data.append: array element out of UInt8 range")
                    }
                    bytes.append(UInt8(b))
                }
                data.append(contentsOf: bytes)
            default:
                throw RuntimeError.invalid(
                    "Data.append: expected a UInt8, Data, or [UInt8], got \(typeName(args[0]))")
            }
            return (.void, boxOpaque(data, typeName: "Data"))
        }
        i.bridges["mutating func Data.append(_:)"] = body
    }

    // MARK: - Process stdio wiring

    /// `process.standardOutput = pipe` — the three stdio slots are
    /// `Any`-typed in Foundation (accepting Pipe or FileHandle), so
    /// the generator can't emit their setters. Same sandbox posture
    /// as every generated Process entry: denied outright when a
    /// sandbox is bound.
    private func registerProcessStandardStreams(into i: Interpreter) {
        #if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
        for slot in ["standardInput", "standardOutput", "standardError"] {
            i.bridges["set var Process.\(slot): Any"] = .setter { receiver, newValue in
                do {
                    try denyProcessIfSandboxed()
                } catch {
                    throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
                }
                let process: Process = try unboxOpaque(receiver, as: Process.self, typeName: "Process")
                guard case .opaque(_, let any) = unwrapForSetter(newValue),
                      any is Pipe || any is FileHandle
                else {
                    throw RuntimeError.invalid("Process.\(slot): expected a Pipe or FileHandle")
                }
                switch slot {
                case "standardInput": process.standardInput = any
                case "standardOutput": process.standardOutput = any
                default: process.standardError = any
                }
            }
            i.bridges["var Process.\(slot): Any"] = .computed { receiver in
                do {
                    try denyProcessIfSandboxed()
                } catch {
                    throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
                }
                let process: Process = try unboxOpaque(receiver, as: Process.self, typeName: "Process")
                let stored: Any? = {
                    switch slot {
                    case "standardInput": return process.standardInput
                    case "standardOutput": return process.standardOutput
                    default: return process.standardError
                    }
                }()
                guard let stored else { return .optional(nil) }
                if let pipe = stored as? Pipe {
                    return boxOpaque(pipe, typeName: "Pipe")
                }
                if let handle = stored as? FileHandle {
                    return boxOpaque(handle, typeName: "FileHandle")
                }
                return .optional(nil)
            }
        }
        #endif
    }

    // MARK: - String search / regex idioms

    /// `s.range(of: pattern, options: .regularExpression)` +
    /// `String(s[range])` + `s.replacingOccurrences(of:with:options:)`
    /// — the stock-Swift regex idiom (issue #7's #2-ranked gap;
    /// regex literals and NSRegularExpression's NSRange surface stay
    /// out of scope). The returned `Range<String.Index>` rides as an
    /// opaque and `doSubscript` slices with it.
    private func registerStringSearchIdioms(into i: Interpreter) {
        // One arity-dispatching body under all three keys — the bare
        // key doubles as the implicit-member context gate
        // (`extensionMethod` consults it before `.regularExpression`
        // resolves against NSString.CompareOptions).
        let rangeBridge = Bridge.method { recv, args in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.range(of:): receiver must be String")
            }
            guard case .string(let pattern) = args.first else {
                throw RuntimeError.invalid("String.range(of:): pattern must be String")
            }
            var options: NSString.CompareOptions = []
            switch args.count {
            case 1:
                break
            case 2:
                guard case .opaque(_, let any) = args[1],
                      let opts = any as? NSString.CompareOptions
                else {
                    throw RuntimeError.invalid("String.range(of:options:): bad options")
                }
                options = opts
            default:
                throw RuntimeError.invalid("String.range: expected 1-2 arguments, got \(args.count)")
            }
            guard let range = s.range(of: pattern, options: options) else {
                return .optional(nil)
            }
            return .optional(.opaque(typeName: "Range<String.Index>", value: range))
        }
        i.bridges["func String.range()"] = rangeBridge
        i.bridges["func String.range(of:)"] = rangeBridge
        i.bridges["func String.range(of:options:)"] = rangeBridge
        i.bridges["func String.replacingOccurrences(of:with:options:)"] = .method { recv, args in
            guard case .string(let s) = recv,
                  args.count == 3,
                  case .string(let target) = args[0],
                  case .string(let replacement) = args[1],
                  case .opaque(_, let any) = args[2],
                  let options = any as? NSString.CompareOptions
            else {
                throw RuntimeError.invalid(
                    "String.replacingOccurrences(of:with:options:): expected (String, String, CompareOptions)")
            }
            return .string(s.replacingOccurrences(
                of: target, with: replacement, options: options))
        }
    }

    /// `components(separatedBy:)` takes either a `String` or a
    /// `CharacterSet` in stock Swift — same label, two types. The
    /// generated entry only unboxes CharacterSet, so this runtime-
    /// typed dispatcher owns both the labeled key and the bare
    /// alias (re-registered after `registerGenerated`).
    nonisolated(unsafe) static let stringComponentsBridge: Bridge = .method { recv, args in
        guard case .string(let s) = recv else {
            throw RuntimeError.invalid("String.components: receiver must be String")
        }
        guard args.count == 1 else {
            throw RuntimeError.invalid(
                "String.components(separatedBy:): expected 1 argument, got \(args.count)"
            )
        }
        switch args[0] {
        case .string(let sep):
            return .array(s.components(separatedBy: sep).map(Value.string))
        case .opaque(typeName: "CharacterSet", let any):
            guard let cs = any as? CharacterSet else {
                throw RuntimeError.invalid("String.components: malformed CharacterSet")
            }
            return .array(s.components(separatedBy: cs).map(Value.string))
        default:
            throw RuntimeError.invalid(
                "String.components(separatedBy:): argument must be String or CharacterSet, got \(typeName(args[0]))"
            )
        }
    }

    // MARK: - Shell-virtualization overrides

    /// Generated bridges answer from the host process; a handful of
    /// them must answer from the *bound shell* instead, or a confined
    /// script sees the embedder's real filesystem layout and identity
    /// (issue #6's "display stays virtual" contract). Registered after
    /// `registerGenerated` so they replace the generated entries.
    private func registerShellVirtualizationOverrides(into i: Interpreter) {
        // `URL(fileURLWithPath:)` absolutizes a relative spelling
        // against the host process CWD at construction, which made the
        // URL door disagree with the String door (whose gate anchors
        // to the shell's logical CWD). Anchor lexically to the shell
        // CWD instead — the spelling stays script-visible text; the
        // gate translates it at I/O time.
        func anchoredFileURL(_ path: String) -> URL {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            let cwd = ShellKit.Shell.current.environment.workingDirectory
            guard !cwd.isEmpty else { return URL(fileURLWithPath: path) }
            if path.isEmpty {
                return URL(fileURLWithPath: cwd, isDirectory: true)
            }
            return URL(fileURLWithPath: ShellKit.Shell.normalizePath(cwd + "/" + path))
        }
        i.bridges["init URL(fileURLWithPath:)"] = .`init` { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("init URL(fileURLWithPath:): expected 1 argument(s), got \(args.count)")
            }
            return boxOpaque(anchoredFileURL(try unboxString(args[0])), typeName: "URL")
        }
        i.bridges["init URL(fileURLWithPath:isDirectory:)"] = .`init` { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("init URL(fileURLWithPath:isDirectory:): expected 2 argument(s), got \(args.count)")
            }
            let anchored = anchoredFileURL(try unboxString(args[0]))
            return boxOpaque(
                URL(fileURLWithPath: anchored.path, isDirectory: try unboxBool(args[1])),
                typeName: "URL")
        }
        // The `relativeTo:` overloads: when a base URL is given, honour
        // it; when it's nil, anchor to the shell's virtual CWD like the
        // no-base inits (otherwise Foundation would absolutize against
        // the host process CWD, leaking the host workspace and making
        // later gated access resolve a host-absolute path).
        i.bridges["init URL(fileURLWithPath:relativeTo:)"] = .`init` { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("init URL(fileURLWithPath:relativeTo:): expected 2 argument(s), got \(args.count)")
            }
            let path = try unboxString(args[0])
            if let base = try unboxOptionalValue(args[1]).map({
                try unboxOpaque($0, as: URL.self, typeName: "URL")
            }) {
                return boxOpaque(URL(fileURLWithPath: path, relativeTo: base), typeName: "URL")
            }
            return boxOpaque(anchoredFileURL(path), typeName: "URL")
        }
        i.bridges["init URL(fileURLWithPath:isDirectory:relativeTo:)"] = .`init` { args in
            guard args.count == 3 else {
                throw RuntimeError.invalid("init URL(fileURLWithPath:isDirectory:relativeTo:): expected 3 argument(s), got \(args.count)")
            }
            let path = try unboxString(args[0])
            let isDir = try unboxBool(args[1])
            if let base = try unboxOptionalValue(args[2]).map({
                try unboxOpaque($0, as: URL.self, typeName: "URL")
            }) {
                return boxOpaque(URL(fileURLWithPath: path, isDirectory: isDir, relativeTo: base), typeName: "URL")
            }
            let anchored = anchoredFileURL(path)
            return boxOpaque(URL(fileURLWithPath: anchored.path, isDirectory: isDir), typeName: "URL")
        }
        // Statics whose generated form captures the host value once at
        // registration. `.staticComputed` re-reads the bound shell on
        // every access; standalone (no sandbox) the shell accessors
        // fall through to the same host answers as before.
        i.bridges["static let URL.temporaryDirectory"] = .staticComputed {
            boxOpaque(
                URL(fileURLWithPath: ShellKit.Shell.displayPath(for: ShellKit.Shell.temporaryDirectory),
                    isDirectory: true),
                typeName: "URL")
        }
        i.bridges["static let URL.homeDirectory"] = .staticComputed {
            boxOpaque(
                URL(fileURLWithPath: ShellKit.Shell.displayPath(for: ShellKit.Shell.homeDirectory),
                    isDirectory: true),
                typeName: "URL")
        }
        i.bridges["static func URL.currentDirectory()"] = .staticMethod { args in
            guard args.isEmpty else {
                throw RuntimeError.invalid("URL.currentDirectory(): expected 0 argument(s), got \(args.count)")
            }
            // Same source of truth as `FileManager.currentDirectoryPath`:
            // the shell's logical CWD (virtual spelling), host CWD only
            // when no embedder bound one.
            let cwd = ShellKit.Shell.current.environment.workingDirectory
            let path = cwd.isEmpty ? FileManager.default.currentDirectoryPath : cwd
            return boxOpaque(URL(fileURLWithPath: path, isDirectory: true), typeName: "URL")
        }
        // Global functions with the same host-capture problem. Under a
        // sandbox they fold through the shell; standalone they keep the
        // stock Foundation answers byte-for-byte (including
        // NSTemporaryDirectory's trailing slash).
        i.registerGlobal(name: "NSTemporaryDirectory") { args in
            guard args.isEmpty else {
                throw RuntimeError.invalid("NSTemporaryDirectory: expected 0 argument(s), got \(args.count)")
            }
            guard ShellKit.Shell.current.sandbox != nil else {
                return .string(NSTemporaryDirectory())
            }
            return .string(ShellKit.Shell.displayPath(for: ShellKit.Shell.temporaryDirectory))
        }
        i.registerGlobal(name: "NSHomeDirectory") { args in
            guard args.isEmpty else {
                throw RuntimeError.invalid("NSHomeDirectory: expected 0 argument(s), got \(args.count)")
            }
            guard ShellKit.Shell.current.sandbox != nil else {
                return .string(NSHomeDirectory())
            }
            return .string(ShellKit.Shell.displayPath(for: ShellKit.Shell.homeDirectory))
        }
        // Identity globals route to the same HostInfo the ProcessInfo
        // redirects use.
        i.registerGlobal(name: "NSUserName") { args in
            guard args.isEmpty else {
                throw RuntimeError.invalid("NSUserName: expected 0 argument(s), got \(args.count)")
            }
            return .string(hostUserName())
        }
        i.registerGlobal(name: "NSFullUserName") { args in
            guard args.isEmpty else {
                throw RuntimeError.invalid("NSFullUserName: expected 0 argument(s), got \(args.count)")
            }
            return .string(hostFullUserName())
        }
    }

    // MARK: - Data subscripts

    /// `data[0]` (byte read), `data[0..<4]` / `data[1...2]` (sub-Data,
    /// rebased to zero), `data[0] = 255` (byte write). Routed through
    /// the `.subscriptGet` / `.subscriptSet` bridge kinds — the same
    /// door any external module uses to expose subscript-first APIs
    /// (issue #9). Data is a value type, so the setter returns a
    /// fresh box for the assignment site to write back.
    private func registerDataSubscripts(into i: Interpreter) {
        i.bridges[i.bridgeKey(forSubscriptGetOn: "Data")] = .subscriptGet { receiver, args in
            let data: Data = try unboxOpaque(receiver, as: Data.self, typeName: "Data")
            guard args.count == 1 else {
                throw RuntimeError.invalid("Data subscript expects 1 argument, got \(args.count)")
            }
            // Indices are absolute (Data's Index == Int), matching
            // stock: a fresh Data starts at 0, but a slice keeps the
            // parent's indices, so `d[1..<3][1]` reads absolute 1.
            switch args[0] {
            case .int(let i):
                guard i >= data.startIndex && i < data.endIndex else {
                    throw RuntimeError.invalid(
                        "Data index \(i) out of bounds (\(data.startIndex)..<\(data.endIndex))"
                    )
                }
                return .int(Int(data[i]))
            case .range(let lo, let hi, let closed):
                let upper = closed ? hi + 1 : hi
                guard lo >= data.startIndex, upper <= data.endIndex, lo <= upper else {
                    throw RuntimeError.invalid(
                        "Data slice \(lo)..<\(upper) out of bounds (\(data.startIndex)..<\(data.endIndex))"
                    )
                }
                // Slice, don't `subdata` — stock `Data` range subscripts
                // keep the parent's absolute indices, so the returned
                // Data must not rebase to zero.
                return boxOpaque(data[lo..<upper], typeName: "Data")
            default:
                throw RuntimeError.invalid(
                    "cannot subscript Data with \(typeName(args[0]))"
                )
            }
        }
        i.bridges[i.bridgeKey(forSubscriptSetOn: "Data")] = .subscriptSet { receiver, args, newValue in
            var data: Data = try unboxOpaque(receiver, as: Data.self, typeName: "Data")
            guard args.count == 1, case .int(let index) = args[0] else {
                throw RuntimeError.invalid("Data subscript assignment expects 1 Int index")
            }
            guard index >= data.startIndex && index < data.endIndex else {
                throw RuntimeError.invalid(
                    "Data index \(index) out of bounds (\(data.startIndex)..<\(data.endIndex))"
                )
            }
            guard case .int(let byte) = newValue, (0...255).contains(byte) else {
                throw RuntimeError.invalid(
                    "Data subscript assignment expects a UInt8 (0...255) value"
                )
            }
            data[index] = UInt8(byte)
            return boxOpaque(data, typeName: "Data")
        }
    }

    // MARK: - C math globals

    private func registerCMathGlobals(into i: Interpreter) {
        let unary: [(String, (Double) -> Double)] = [
            ("sqrt",  Foundation.sqrt),
            ("cbrt",  Foundation.cbrt),
            ("sin",   Foundation.sin),
            ("cos",   Foundation.cos),
            ("tan",   Foundation.tan),
            ("asin",  Foundation.asin),
            ("acos",  Foundation.acos),
            ("atan",  Foundation.atan),
            ("sinh",  Foundation.sinh),
            ("cosh",  Foundation.cosh),
            ("tanh",  Foundation.tanh),
            ("log",   Foundation.log),
            ("log2",  Foundation.log2),
            ("log10", Foundation.log10),
            ("exp",   Foundation.exp),
            ("exp2",  Foundation.exp2),
            ("floor", Foundation.floor),
            ("ceil",  Foundation.ceil),
            ("round", Foundation.round),
            ("trunc", Foundation.trunc),
        ]
        for (fnName, fn) in unary {
            let captured = fnName
            i.registerGlobal(name: fnName) { args in
                guard args.count == 1 else {
                    throw RuntimeError.invalid("\(captured): expected 1 argument, got \(args.count)")
                }
                return .double(fn(try toDouble(args[0])))
            }
        }
        i.registerGlobal(name: "pow") { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("pow: expected 2 arguments, got \(args.count)")
            }
            return .double(Foundation.pow(try toDouble(args[0]), try toDouble(args[1])))
        }
        i.registerGlobal(name: "atan2") { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("atan2: expected 2 arguments, got \(args.count)")
            }
            return .double(Foundation.atan2(try toDouble(args[0]), try toDouble(args[1])))
        }
        i.registerGlobal(name: "hypot") { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("hypot: expected 2 arguments, got \(args.count)")
            }
            return .double(Foundation.hypot(try toDouble(args[0]), try toDouble(args[1])))
        }
        i.registerGlobal(name: "copysign") { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("copysign: expected 2 arguments, got \(args.count)")
            }
            return .double(Foundation.copysign(try toDouble(args[0]), try toDouble(args[1])))
        }
        i.registerGlobal(name: "fmod") { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("fmod: expected 2 arguments, got \(args.count)")
            }
            return .double(Foundation.fmod(try toDouble(args[0]), try toDouble(args[1])))
        }
        i.registerGlobal(name: "remainder") { args in
            guard args.count == 2 else {
                throw RuntimeError.invalid("remainder: expected 2 arguments, got \(args.count)")
            }
            return .double(Foundation.remainder(try toDouble(args[0]), try toDouble(args[1])))
        }
    }

    // MARK: - C math constants

    private func registerCMathConstants(into i: Interpreter) {
        // Literal value of <math.h>'s M_E. Hardcoded because Swift on Windows
        // does not re-export M_E through Foundation.
        let eulerNumber = 2.71828182845904523536028747135266250
        i.registerGlobal(name: "M_PI") { _ in .double(.pi) }
        i.registerGlobal(name: "M_E")  { _ in .double(eulerNumber) }
        // We also keep convenience bare globals so existing scripts that
        // wrote `pi` / `e` keep working when Foundation is imported. Real
        // Swift doesn't have these — they're an interpreter convenience.
        i.registerGlobal(name: "pi") { _ in .double(.pi) }
        i.registerGlobal(name: "e")  { _ in .double(eulerNumber) }
    }

    // MARK: - Foundation-only String methods

    private func registerStringMethods(into i: Interpreter) {
        i.bridges["func String.replacingOccurrences()"] = .method { recv, args in
            guard args.count == 2,
                  case .string(let s) = recv,
                  case .string(let target) = args[0],
                  case .string(let repl) = args[1]
            else {
                throw RuntimeError.invalid(
                    "String.replacingOccurrences(of:with:): bad arguments"
                )
            }
            return .string(s.replacingOccurrences(of: target, with: repl))
        }
        // `trimmingCharacters(in:)` is auto-generated from the Foundation
        // symbol graph — see `FoundationBridge.generated.swift`.
        i.bridges["func String.padding()"] = .method { recv, args in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.padding: receiver must be String")
            }
            guard args.count == 3,
                  case .int(let n) = args[0],
                  case .string(let p) = args[1],
                  case .int(let i) = args[2]
            else {
                throw RuntimeError.invalid(
                    "String.padding(toLength:withPad:startingAt:): expected (Int, String, Int)"
                )
            }
            return .string(s.padding(toLength: n, withPad: p, startingAt: i))
        }
        // Shared with the post-`registerGenerated` re-registration —
        // see `stringComponentsBridge`.
        i.bridges["func String.components()"] = Self.stringComponentsBridge
    }
}

