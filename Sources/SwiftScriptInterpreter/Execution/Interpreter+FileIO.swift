import Foundation
import ShellKit
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
    ///
    /// **Sandbox-aware**: routes the path through ``authorizePath(_:for:)``
    /// before reading from disk so an embedder's bound sandbox can deny
    /// off-root access.
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
        let hostPath: String
        do {
            hostPath = try await authorizePath(path, for: .read)
        } catch {
            throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
        }
        do {
            let s = try String(contentsOfFile: hostPath, encoding: .utf8)
            return .string(s)
        } catch {
            throw UserThrowSignal(value: .string(error.localizedDescription))
        }
    }

    /// Dispatch a method call on the `FileManager` singleton sentinel.
    /// Each method authorises its path arg(s) against the bound shell's
    /// sandbox and then does its Foundation I/O on the *returned* host
    /// path — under a path-mapped sandbox the script-visible virtual
    /// spelling and the directory that backs it differ, and check and
    /// I/O must agree on the host form.
    func invokeFileManagerMethod(
        _ name: String,
        args: [Value],
        labels: [String?]? = nil
    ) async throws -> Value {
        switch name {
        case "fileExists":
            try expectStringArg(args, methodName: "FileManager.fileExists(atPath:)")
            if case .string(let path) = args[0] {
                let hostPath = try await gatePath(path, for: .read,
                                   methodName: "FileManager.fileExists(atPath:)")
                return .bool(FileManager.default.fileExists(atPath: hostPath))
            }
        case "contentsOfDirectory":
            try expectStringArg(args, methodName: "FileManager.contentsOfDirectory(atPath:)")
            if case .string(let path) = args[0] {
                let hostPath = try await gatePath(path, for: .read,
                                   methodName: "FileManager.contentsOfDirectory(atPath:)")
                do {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: hostPath)
                    return .array(entries.map { .string($0) })
                } catch {
                    throw UserThrowSignal(value: .string(error.localizedDescription))
                }
            }
        case "removeItem":
            try expectStringArg(args, methodName: "FileManager.removeItem(atPath:)")
            if case .string(let path) = args[0] {
                let hostPath = try await gatePath(path, for: .delete,
                                   methodName: "FileManager.removeItem(atPath:)")
                do {
                    try FileManager.default.removeItem(atPath: hostPath)
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
            let hostPath = try await gatePath(path, for: .write,
                               methodName: "FileManager.createDirectory(atPath:)")
            do {
                try FileManager.default.createDirectory(
                    atPath: hostPath,
                    withIntermediateDirectories: intermediate,
                    attributes: nil
                )
                return .void
            } catch {
                throw UserThrowSignal(value: .string(error.localizedDescription))
            }
        case "changeCurrentDirectoryPath":
            // Virtual `cd`: updates the bound shell's logical CWD (the
            // one `resolve(_:)` anchors relative paths to and
            // `currentDirectoryPath` reports) instead of chdir-ing the
            // host process — a real chdir would escape the mapping and
            // leak the embedder's host layout into later relative
            // resolutions. Mirrors `FileManager`'s Bool contract:
            // false when the target isn't an existing directory.
            try expectStringArg(args, methodName: "FileManager.changeCurrentDirectoryPath(_:)")
            if case .string(let path) = args[0] {
                let hostPath = try await gatePath(path, for: .read,
                                   methodName: "FileManager.changeCurrentDirectoryPath(_:)")
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { return .bool(false) }
                ShellKit.Shell.current.environment.workingDirectory =
                    ShellKit.Shell.current.displayPath(for: hostPath)
                return .bool(true)
            }
        default: break
        }
        // Everything else falls through to the auto-generated
        // FileManager bridges (copyItem, moveItem, contents,
        // isReadableFile, …). They unbox an `.opaque` receiver, so
        // hand them a real box — the sentinel is a `.structValue`
        // used only for dispatch identity. The hardcoded cases above
        // stay first because their semantics are virtualised (logical
        // cwd, [String] listings) rather than raw Foundation.
        // Label-keyed overload first, then the bare-key alias.
        if let labels, !labels.isEmpty,
           case .method(let body)? =
            bridges[bridgeKey(forMethod: name, on: "FileManager", labels: labels)]
        {
            return try await body(
                boxOpaque(FileManager.default, typeName: "FileManager"), args)
        }
        if case .method(let body)? =
            bridges[bridgeKey(forMethod: name, on: "FileManager", labels: [])]
        {
            return try await body(
                boxOpaque(FileManager.default, typeName: "FileManager"), args)
        }
        throw RuntimeError.invalid("'FileManager' has no method '\(name)'")
    }

    /// Detect `str.write(toFile:atomically:encoding:)` and route through
    /// Foundation. Returns nil if the call doesn't match. We handle this
    /// at the call-dispatch level (before arg evaluation) because the
    /// `encoding:` argument is typically `.utf8` — an implicit-member
    /// expression we can't otherwise resolve without `String.Encoding`.
    /// Gated on Foundation import.
    ///
    /// **Sandbox-aware**: the path arg is authorized for `.write` before
    /// the `String.write(toFile:)` call.
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
        let hostPath = try await gatePath(path, for: .write,
                           methodName: "String.write(toFile:)")
        do {
            try s.write(toFile: hostPath, atomically: atomically, encoding: .utf8)
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

    /// Shared sandbox-gate path used by every fast-path FileManager
    /// dispatch. Wraps the denial as a `UserThrowSignal` so the call
    /// site error path stays consistent with the auto-generated
    /// bridges. Returns the resolved host path — the caller's
    /// Foundation call must consume it, never the original spelling.
    private func gatePath(
        _ path: String,
        for intent: PathAccessIntent,
        methodName: String
    ) async throws -> String {
        do {
            return try await authorizePath(path, for: intent)
        } catch {
            throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
        }
    }
}
