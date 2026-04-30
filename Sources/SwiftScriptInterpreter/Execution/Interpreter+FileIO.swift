import Foundation
import SwiftSyntax

extension Interpreter {
    /// `FileManager.default` returns a sentinel struct value whose methods
    /// (`fileExists(atPath:)`, `contentsOfDirectory(atPath:)`, …) are
    /// recognized in `invokeFileManagerMethod`.
    var fileManagerSentinel: Value {
        .structValue(typeName: "FileManager", fields: [])
    }

    /// Detect `String(contentsOfFile:encoding:)` and call into Foundation.
    /// Returns nil if the call doesn't match — caller falls through to the
    /// regular `String(...)` builtin dispatch. Gated on Foundation import:
    /// without it, the path is dormant and the call falls through to the
    /// stdlib String builtin which will reject the labeled args.
    func tryStringContentsOfFile(_ call: FunctionCallExprSyntax, in scope: Scope) async throws -> Value? {
        guard isImported(any: "Foundation", "Darwin", "Glibc", "ucrt", "WinSDK") else { return nil }
        guard let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
              ref.baseName.text == "String",
              let firstArg = call.arguments.first,
              firstArg.label?.text == "contentsOfFile"
        else {
            return nil
        }
        // The encoding arg (typically `.utf8`) is parsed as an implicit
        // member but we don't model the String.Encoding type — just ignore
        // it. We always read as UTF-8.
        let pathValue = try await evaluate(firstArg.expression, in: scope)
        guard case .string(let path) = pathValue else {
            throw RuntimeError.invalid("String(contentsOfFile:): path must be String")
        }
        do {
            let s = try String(contentsOfFile: path, encoding: .utf8)
            return .string(s)
        } catch {
            throw UserThrowSignal(value: .string(error.localizedDescription))
        }
    }

    /// Dispatch a method call on the `FileManager` singleton sentinel.
    func invokeFileManagerMethod(_ name: String, args: [Value]) async throws -> Value {
        switch name {
        case "fileExists":
            try expectStringArg(args, methodName: "FileManager.fileExists(atPath:)")
            if case .string(let path) = args[0] {
                return .bool(FileManager.default.fileExists(atPath: path))
            }
        case "contentsOfDirectory":
            try expectStringArg(args, methodName: "FileManager.contentsOfDirectory(atPath:)")
            if case .string(let path) = args[0] {
                do {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: path)
                    return .array(entries.map { .string($0) })
                } catch {
                    throw UserThrowSignal(value: .string(error.localizedDescription))
                }
            }
        case "removeItem":
            try expectStringArg(args, methodName: "FileManager.removeItem(atPath:)")
            if case .string(let path) = args[0] {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    return .void
                } catch {
                    throw UserThrowSignal(value: .string(error.localizedDescription))
                }
            }
        case "createDirectory":
            // Accept the (atPath:withIntermediateDirectories:) form,
            // ignoring optional attributes.
            guard args.count >= 2,
                  case .string(let path) = args[0],
                  case .bool(let intermediate) = args[1]
            else {
                throw RuntimeError.invalid(
                    "FileManager.createDirectory(atPath:withIntermediateDirectories:): bad args"
                )
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: intermediate,
                    attributes: nil
                )
                return .void
            } catch {
                throw UserThrowSignal(value: .string(error.localizedDescription))
            }
        default: break
        }
        throw RuntimeError.invalid("'FileManager' has no method '\(name)'")
    }

    /// Detect `str.write(toFile:atomically:encoding:)` and route through
    /// Foundation. Returns nil if the call doesn't match. We handle this
    /// at the call-dispatch level (before arg evaluation) because the
    /// `encoding:` argument is typically `.utf8` — an implicit-member
    /// expression we can't otherwise resolve without `String.Encoding`.
    /// Gated on Foundation import.
    func tryStringWriteCall(_ call: FunctionCallExprSyntax, in scope: Scope) async throws -> Value? {
        guard isImported(any: "Foundation", "Darwin", "Glibc", "ucrt", "WinSDK") else { return nil }
        guard let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = memberAccess.base,
              memberAccess.declName.baseName.text == "write"
        else { return nil }
        let argSyntaxes = Array(call.arguments)
        guard let firstLabel = argSyntaxes.first?.label?.text, firstLabel == "toFile" else {
            return nil
        }
        let receiver = try await evaluate(base, in: scope)
        guard case .string(let s) = receiver else { return nil }
        let pathValue = try await evaluate(argSyntaxes[0].expression, in: scope)
        guard case .string(let path) = pathValue else {
            throw RuntimeError.invalid("write(toFile:): path must be String")
        }
        // atomically: defaults to true; accept the arg if present.
        var atomically = true
        if argSyntaxes.count >= 2, argSyntaxes[1].label?.text == "atomically" {
            let v = try await evaluate(argSyntaxes[1].expression, in: scope)
            if case .bool(let b) = v { atomically = b }
        }
        // The third arg (encoding:) is intentionally ignored — we always
        // use UTF-8.
        do {
            try s.write(toFile: path, atomically: atomically, encoding: .utf8)
            return .void
        } catch {
            throw UserThrowSignal(value: .string(error.localizedDescription))
        }
    }

    private func expectStringArg(_ args: [Value], methodName: String) throws {
        guard args.count == 1 else {
            throw RuntimeError.invalid("\(methodName): expected 1 argument")
        }
        guard case .string = args[0] else {
            throw RuntimeError.invalid("\(methodName): argument must be String")
        }
    }
}
