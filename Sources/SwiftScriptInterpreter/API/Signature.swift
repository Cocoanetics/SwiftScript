import Foundation
import SwiftSyntax
import SwiftParser

/// Parsed view of a bridge key. The string key is the source of truth
/// (greppable, declarative, identical to the Swift declaration); this
/// struct is the cached parse used at call time for matching.
///
/// Supported key shapes:
///
///     "init Type(label1:label2:)"
///     "init Type<T: Constraint>(label: T)"
///     "var Type.property: ReturnType"
///     "func Type.method(label1:label2:) throws -> Return"
///     "func Type.method<T: Constraint, U>(_: T, _: U) -> T"
///     "static let Type.property: ReturnType"
///     "static func Type.method(...) -> Return"
public struct Signature: Sendable {
    public enum Kind: Sendable {
        case `init`
        case method
        case staticMethod
        case computed
        case staticValue
    }

    public struct Parameter: Sendable {
        /// External label seen at the call site. `nil` for `_:`.
        public let label: String?
        /// Internal name (used in `missing argument for parameter '<name>'`).
        public let name: String
        /// Declared type spelling — `"Int"`, `"T"`, `"T.Type"`, `"[Int]"`.
        public let type: String
    }

    public struct GenericParameter: Sendable {
        public let name: String              // "T"
        public let constraints: [String]     // ["Encodable", "Sendable"]
    }

    public let kind: Kind
    public let receiver: String              // owning type, e.g. "JSONEncoder"
    public let memberName: String?           // "encode" / "absoluteString" / nil for init
    public let parameters: [Parameter]
    public let generics: [GenericParameter]
    /// `nil` for void / no-return; otherwise the return-type spelling.
    public let returnType: String?
    public let isThrowing: Bool
    public let isFailable: Bool              // for `init?(...)`

    /// True if any parameter / return type mentions one of the
    /// generics. Generics-free signatures use the fast path.
    public var isGeneric: Bool { !generics.isEmpty }
}

public enum SignatureParseError: Error, CustomStringConvertible {
    case unrecognizedShape(String)
    case syntaxError(String)
    public var description: String {
        switch self {
        case .unrecognizedShape(let key): return "unrecognized bridge key shape: '\(key)'"
        case .syntaxError(let key): return "could not parse bridge key as Swift: '\(key)'"
        }
    }
}

extension Signature {
    /// Parse a bridge key into a `Signature`. The key is wrapped into a
    /// minimal Swift extension declaration so SwiftSyntax can do the
    /// heavy lifting; we then pull the parts we need out of the syntax
    /// tree.
    public static func parse(_ key: String) throws -> Signature {
        // Detect kind from the leading keyword.
        if key.hasPrefix("init ") {
            return try parseInit(stripping: "init ", from: key)
        }
        if key.hasPrefix("var ") {
            return try parseProperty(stripping: "var ", from: key, isStatic: false)
        }
        if key.hasPrefix("static let ") {
            return try parseStaticValue(stripping: "static let ", from: key)
        }
        if key.hasPrefix("static func ") {
            return try parseFunction(stripping: "static func ", from: key, isStatic: true)
        }
        if key.hasPrefix("func ") {
            return try parseFunction(stripping: "func ", from: key, isStatic: false)
        }
        throw SignatureParseError.unrecognizedShape(key)
    }

    // MARK: - per-kind parsers

    private static func parseInit(stripping prefix: String, from key: String) throws -> Signature {
        // "init Type(...)"  /  "init Type?(...)"  /  "init Type<T: P>(...)"
        let body = String(key.dropFirst(prefix.count))
        // Receiver is everything up to the first `<` or `(`.
        let (receiver, rest) = splitAtTypeEnd(body)
        let (failableMark, afterMark) = peelOptional(rest)
        let isFailable = failableMark
        // Easiest: wrap the init signature as a static func returning
        // the type and reuse the function-parsing path. (We previously
        // tried `struct __Probe<…>` but switched to function form.)
        let funcSrc = "func __probe\(afterMark) -> \(receiver) { fatalError() }"
        let parsed = Parser.parse(source: funcSrc)
        guard let fnDecl = parsed.statements.first?.item.as(FunctionDeclSyntax.self) else {
            throw SignatureParseError.syntaxError(key)
        }
        let (params, generics, _, throwsFlag) = extract(from: fnDecl)
        return Signature(
            kind: .`init`,
            receiver: receiver,
            memberName: nil,
            parameters: params,
            generics: generics,
            returnType: receiver,
            isThrowing: throwsFlag,
            isFailable: isFailable
        )
    }

    private static func parseFunction(
        stripping prefix: String, from key: String, isStatic: Bool
    ) throws -> Signature {
        // "func Type.method<T>(...) throws -> Return"
        let body = String(key.dropFirst(prefix.count))
        // The method's qualified name: Type.method.
        // Receiver is everything up to the LAST `.` before `<` or `(`.
        let (qualName, sigTail) = splitAtTypeEnd(body)
        let dot = qualName.lastIndex(of: ".")!
        let receiver = String(qualName[..<dot])
        let methodName = String(qualName[qualName.index(after: dot)...])
        // Reconstruct as a free function: `func methodName<...>(...) ...`
        let funcSrc = "func \(methodName)\(sigTail) {}"
        let parsed = Parser.parse(source: funcSrc)
        guard let fnDecl = parsed.statements.first?.item.as(FunctionDeclSyntax.self) else {
            throw SignatureParseError.syntaxError(key)
        }
        let (params, generics, ret, throwsFlag) = extract(from: fnDecl)
        return Signature(
            kind: isStatic ? .staticMethod : .method,
            receiver: receiver,
            memberName: methodName,
            parameters: params,
            generics: generics,
            returnType: ret,
            isThrowing: throwsFlag,
            isFailable: false
        )
    }

    private static func parseProperty(
        stripping prefix: String, from key: String, isStatic: Bool
    ) throws -> Signature {
        // "var Type.property: Return"
        let body = String(key.dropFirst(prefix.count))
        guard let colon = body.firstIndex(of: ":") else {
            throw SignatureParseError.unrecognizedShape(key)
        }
        let qualName = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
        let returnSpelling = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard let dot = qualName.lastIndex(of: ".") else {
            throw SignatureParseError.unrecognizedShape(key)
        }
        let receiver = String(qualName[..<dot])
        let propName = String(qualName[qualName.index(after: dot)...])
        return Signature(
            kind: .computed,
            receiver: receiver,
            memberName: propName,
            parameters: [],
            generics: [],
            returnType: returnSpelling.isEmpty ? nil : returnSpelling,
            isThrowing: false,
            isFailable: false
        )
    }

    private static func parseStaticValue(
        stripping prefix: String, from key: String
    ) throws -> Signature {
        // "static let Type.member: Return"  (`: Return` optional)
        let body = String(key.dropFirst(prefix.count))
        let qualName: String
        let returnSpelling: String?
        if let colon = body.firstIndex(of: ":") {
            qualName = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            returnSpelling = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            qualName = body.trimmingCharacters(in: .whitespaces)
            returnSpelling = nil
        }
        guard let dot = qualName.lastIndex(of: ".") else {
            throw SignatureParseError.unrecognizedShape(key)
        }
        let receiver = String(qualName[..<dot])
        let memberName = String(qualName[qualName.index(after: dot)...])
        return Signature(
            kind: .staticValue,
            receiver: receiver,
            memberName: memberName,
            parameters: [],
            generics: [],
            returnType: returnSpelling,
            isThrowing: false,
            isFailable: false
        )
    }

    // MARK: - helpers

    /// Split at the first `<` (generic clause), `(` (param list), or
    /// `:` (return for properties). Returns `(typeArea, signatureTail)`.
    private static func splitAtTypeEnd(_ body: String) -> (String, String) {
        for (i, c) in body.enumerated() where c == "<" || c == "(" || c == "?" {
            let idx = body.index(body.startIndex, offsetBy: i)
            return (String(body[..<idx]), String(body[idx...]))
        }
        return (body, "")
    }

    private static func peelOptional(_ tail: String) -> (Bool, String) {
        if tail.hasPrefix("?") { return (true, String(tail.dropFirst())) }
        return (false, tail)
    }

    private static func probeGenericsAndParams(_ tail: String) -> String {
        // Stub: SwiftSyntax does the actual parsing. Used only by the
        // init-via-struct fallback (currently unused).
        tail
    }

    /// Pull params, generics, return type, throws-flag from a parsed
    /// `func` syntax node.
    private static func extract(from fn: FunctionDeclSyntax) -> (
        params: [Parameter],
        generics: [GenericParameter],
        returnType: String?,
        isThrowing: Bool
    ) {
        var params: [Parameter] = []
        for p in fn.signature.parameterClause.parameters {
            let firstName = p.firstName.text
            let label: String? = (firstName == "_") ? nil : firstName
            let internalName = p.secondName?.text ?? firstName
            let typeSpelling = p.type.description.trimmingCharacters(in: .whitespaces)
            params.append(Parameter(label: label, name: internalName, type: typeSpelling))
        }
        var generics: [GenericParameter] = []
        if let gp = fn.genericParameterClause?.parameters {
            for p in gp {
                let name = p.name.text
                var constraints: [String] = []
                if let inh = p.inheritedType {
                    constraints.append(inh.description.trimmingCharacters(in: .whitespaces))
                }
                generics.append(GenericParameter(name: name, constraints: constraints))
            }
        }
        // `where T: P, U == V` clauses are flattened into per-generic
        // constraints when the generic name is on the LHS; other shapes
        // (same-type) ignored for now.
        if let where_ = fn.genericWhereClause {
            for req in where_.requirements {
                if let conf = req.requirement.as(ConformanceRequirementSyntax.self) {
                    let lhs = conf.leftType.description.trimmingCharacters(in: .whitespaces)
                    let rhs = conf.rightType.description.trimmingCharacters(in: .whitespaces)
                    if let idx = generics.firstIndex(where: { $0.name == lhs }) {
                        generics[idx] = GenericParameter(
                            name: generics[idx].name,
                            constraints: generics[idx].constraints + [rhs]
                        )
                    }
                }
            }
        }
        let ret = fn.signature.returnClause?.type.description.trimmingCharacters(in: .whitespaces)
        let isThrowing = fn.signature.effectSpecifiers?.throwsClause != nil
        return (params, generics, ret, isThrowing)
    }
}
