import Foundation
import SwiftSyntax

extension Interpreter {
    /// Names that should be treated as types when they appear as the receiver
    /// of a member-access expression (so `Int.max` looks up a static member
    /// rather than calling `Int(...)` and trying to access `.max` on the
    /// resulting Function value). User-declared structs are added at
    /// declaration time.
    func isTypeName(_ name: String) -> Bool {
        let resolved = resolveTypeName(name)
        if structDefs[resolved] != nil { return true }
        if classDefs[resolved] != nil { return true }
        if enumDefs[resolved] != nil { return true }
        // Any name with registered extension data — static members or
        // initializers — counts as a type. This covers types like
        // `CharacterSet` (static members) and `Set`/`URL` (initializers)
        // surfaced by auto-generated bridges. Extensions are only
        // populated after the relevant module loads, so this is
        // correctly import-gated.
        if let ext = extensions[resolved],
           !(ext.staticMembers.isEmpty && ext.initializers.isEmpty)
        {
            return true
        }
        switch resolved {
        case "Int", "Double", "String", "Bool", "Array", "Range", "Optional":
            return true
        case "FileManager":
            // Foundation type with hand-rolled dispatch — only visible
            // after `import Foundation`.
            return isImported(any: "Foundation", "Darwin", "Glibc")
        default:
            return false
        }
    }

    /// Look up a static property (`Int.max`, `Double.pi`) or static method
    /// (`Int.random`, `Double.random`) on a type. Returns either a value
    /// directly, or a `.function` for callable members.
    func lookupStaticMember(typeName rawTypeName: String, member: String, at offset: Int) async throws -> Value {
        // Resolve through any typealias before looking anything up.
        let typeName = resolveTypeName(rawTypeName)
        // User-defined struct: check its static members first.
        if let def = structDefs[typeName], let v = def.staticMembers[member] {
            return v
        }
        // User-defined class: walk the inheritance chain so subclasses
        // inherit static members. Closest-class wins on shadowing.
        if classDefs[typeName] != nil {
            for def in classDefChain(typeName) {
                if let v = def.staticMembers[member] { return v }
            }
        }
        // User-defined enum: cases double as static-style accessors.
        if enumDefs[typeName] != nil {
            if let caseValue = enumCaseAccess(typeName: typeName, caseName: member) {
                return caseValue
            }
            if let v = enumDefs[typeName]?.staticMembers[member] {
                return v
            }
        }
        // User extension on a built-in type.
        if let v = extensions[typeName]?.staticMembers[member] {
            return v
        }
        switch (typeName, member) {
        case ("FileManager", "default") where isImported(any: "Foundation", "Darwin", "Glibc"):
            return fileManagerSentinel
        // `random(in:)` returns a closure, so it's not a flat `.value` —
        // not a fit for `registerStaticValue`. Stays hand-rolled.
        case ("Int", "random"):    return staticIntRandom()
        case ("Double", "random"): return staticDoubleRandom()
        case ("Bool", "random"):
            // `Bool.random()` — no-arg static method returning Bool.
            return .function(Function(
                name: "Bool.random",
                parameters: [],
                kind: .builtin({ args in
                    guard args.isEmpty else {
                        throw RuntimeError.invalid("Bool.random(): no arguments")
                    }
                    return .bool(Bool.random())
                })
            ))
        default:
            throw RuntimeError.invalid("type '\(typeName)' has no member '\(member)'")
        }
    }

    private func staticIntRandom() -> Value {
        let fn = Function(name: "Int.random", parameters: [], kind: .builtin({ args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Int.random(in:): expected 1 argument")
            }
            guard case .range(let lo, let hi, let closed) = args[0] else {
                throw RuntimeError.invalid(
                    "Int.random(in:): argument must be a Range, got \(typeName(args[0]))"
                )
            }
            let upper = closed ? hi : hi - 1
            guard upper >= lo else {
                throw RuntimeError.invalid("Int.random(in:): empty range")
            }
            return .int(Int.random(in: lo...upper))
        }))
        return .function(fn)
    }

    private func staticDoubleRandom() -> Value {
        let fn = Function(name: "Double.random", parameters: [], kind: .builtin({ args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Double.random(in:): expected 1 argument")
            }
            // Accept Int ranges too — caller probably wrote `0..<1`.
            switch args[0] {
            case .range(let lo, let hi, let closed):
                let upper = closed ? Double(hi) : Double(hi)
                let bound = Double(lo).nextUp == upper ? upper : upper
                return .double(Double.random(in: Double(lo)..<bound))
            default:
                throw RuntimeError.invalid(
                    "Double.random(in:): argument must be a Range, got \(typeName(args[0]))"
                )
            }
        }))
        return .function(fn)
    }
}
