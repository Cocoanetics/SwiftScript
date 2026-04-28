import Foundation

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
        // Auto-generated Foundation bridges. Regenerate via
        //   bash Tools/regen-foundation-bridge.sh
        // Includes opaque-type comparators driven off `Equatable`/
        // `Comparable` conformances harvested from the symbol graph.
        registerGenerated(into: i)
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
        // `M_PI`, `M_E` come from Darwin's <math.h>; available under
        // `import Foundation` because Foundation re-exports them.
        i.registerGlobal(name: "M_PI") { _ in .double(.pi) }
        i.registerGlobal(name: "M_E")  { _ in .double(M_E) }
        // We also keep convenience bare globals so existing scripts that
        // wrote `pi` / `e` keep working when Foundation is imported. Real
        // Swift doesn't have these — they're an interpreter convenience.
        i.registerGlobal(name: "pi") { _ in .double(.pi) }
        i.registerGlobal(name: "e")  { _ in .double(M_E) }
    }

    // MARK: - Foundation-only String methods

    private func registerStringMethods(into i: Interpreter) {
        i.bridges["String.replacingOccurrences()"] = .method { recv, args in
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
        i.bridges["String.padding()"] = .method { recv, args in
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
        i.bridges["String.components()"] = .method { recv, args in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.components: receiver must be String")
            }
            guard args.count == 1 else {
                throw RuntimeError.invalid(
                    "String.components(separatedBy:): expected 1 argument, got \(args.count)"
                )
            }
            // Real Swift has two overloads — one taking `String`, one taking
            // `CharacterSet`. Dispatch on the runtime value type.
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
    }
}

