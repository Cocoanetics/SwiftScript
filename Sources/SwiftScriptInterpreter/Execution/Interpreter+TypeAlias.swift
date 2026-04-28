import SwiftSyntax

extension Interpreter {
    /// Register `typealias Foo = Bar`. The right-hand side is stored as a
    /// raw `TypeSyntax`; we resolve it lazily wherever type names matter.
    func execute(typeAliasDecl: TypeAliasDeclSyntax, in scope: Scope) async throws -> Value {
        typeAliases[typeAliasDecl.name.text] = typeAliasDecl.initializer.value
        return .void
    }

    /// Resolve a type expression through the alias chain. Returns the
    /// fully-resolved syntax (or the original if no alias applies).
    func resolveType(_ type: TypeSyntax, depth: Int = 0) -> TypeSyntax {
        guard depth < 16 else { return type }
        if let identType = type.as(IdentifierTypeSyntax.self),
           let target = typeAliases[identType.name.text]
        {
            return resolveType(target, depth: depth + 1)
        }
        return type
    }

    /// Resolve a bare type name (e.g. `"Number"`) through the alias chain
    /// to its eventual identifier. Returns the input unchanged if the
    /// alias terminates in a non-identifier type (`[Int]`, `(Int, Int)`).
    func resolveTypeName(_ name: String) -> String {
        guard let target = typeAliases[name] else { return name }
        let resolved = resolveType(target)
        if let identType = resolved.as(IdentifierTypeSyntax.self) {
            return identType.name.text
        }
        return name
    }
}
