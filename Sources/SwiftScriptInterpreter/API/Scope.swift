import SwiftSyntax

/// Lexical scope, reference-typed so closures can hold a reference to their
/// enclosing scope and observe mutations to captured `var` bindings.
public final class Scope {
    public let parent: Scope?
    private var bindings: [String: Binding] = [:]
    /// Bodies of `defer` statements registered in this scope, to be run in
    /// reverse order when the scope exits.
    public var deferred: [CodeBlockSyntax] = []

    public init(parent: Scope? = nil) {
        self.parent = parent
    }

    public func bind(_ name: String, value: Value, mutable: Bool, declaredType: TypeSyntax? = nil) {
        bindings[name] = Binding(value: value, mutable: mutable, declaredType: declaredType)
    }

    public func lookup(_ name: String) -> Binding? {
        if let b = bindings[name] { return b }
        return parent?.lookup(name)
    }

    /// Variant of `lookup` that also returns the scope where the binding
    /// was found. Used to decide whether an outer-captured var should
    /// lose to an implicit-self field (priority depends on whether the
    /// var lives above or at/below the self-binding scope).
    public func lookupWithOwner(_ name: String) -> (Binding, Scope)? {
        if let b = bindings[name] { return (b, self) }
        return parent?.lookupWithOwner(name)
    }

    /// True when `descendant` is reachable from `self` walking parent
    /// links (inclusive). Used by the implicit-self vs outer-capture
    /// resolver to decide which binding wins.
    public func isAncestor(of descendant: Scope) -> Bool {
        var cur: Scope? = descendant
        while let s = cur {
            if s === self { return true }
            cur = s.parent
        }
        return false
    }

    @discardableResult
    public func assign(_ name: String, value: Value) -> Bool {
        if let existing = bindings[name] {
            guard existing.mutable else { return false }
            bindings[name] = Binding(value: value, mutable: true, declaredType: existing.declaredType)
            return true
        }
        return parent?.assign(name, value: value) ?? false
    }

    public struct Binding {
        public var value: Value
        public let mutable: Bool
        /// Type annotation supplied at declaration (`var arr: [Int] = …`).
        /// Used by strict-element checks for mutating methods like
        /// `arr.append(x)` and `arr[i] = x`.
        public let declaredType: TypeSyntax?

        public init(value: Value, mutable: Bool, declaredType: TypeSyntax? = nil) {
            self.value = value
            self.mutable = mutable
            self.declaredType = declaredType
        }
    }

    /// Copy the local (non-inherited) bindings from this scope into `other`.
    /// Used when matching nested patterns: a pattern-match builds a child
    /// scope of bindings, and the caller wants those merged into its own.
    public func copyBindings(into other: Scope) {
        for (name, b) in bindings {
            other.bind(name, value: b.value, mutable: b.mutable)
        }
    }
}
