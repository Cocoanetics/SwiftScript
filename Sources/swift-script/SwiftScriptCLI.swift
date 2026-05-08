import Foundation
import SwiftScriptInterpreter
import ShellKit

/// CLI entry. Wrapped in a `@main` struct (rather than top-level code)
/// so `main()` is nonisolated — top-level code becomes implicitly
/// `@MainActor`-isolated under Swift 6 strict concurrency, which makes
/// the `try await interpreter.eval(...)` call cross an actor boundary
/// and trip on `Value` not being `Sendable`. Keeping `main` nonisolated
/// matches where the interpreter actually runs.
///
/// All IO routes through ``ShellKit/Shell/current`` — in standalone
/// mode that resolves to ``ShellKit/Shell/processDefault`` whose
/// stdout / stderr forward to real `FileHandle.standard*`, so the
/// binary behaves exactly as before. Under an embedder (SwiftBash,
/// an iOS app) the bound Shell's sinks receive the bytes instead.
@main
struct SwiftScriptCLI {
    static func usage() -> Never {
        Shell.current.stderr("""
            usage: swift-script <file.swift>
                   swift-script -e <expression>

            """)
        exit(2)
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage() }

        let source: String
        let fileName: String
        let isInline: Bool
        // Script-side `CommandLine.arguments`: index 0 is the script path
        // (or `<expression>` for `-e`), then any extra positional args
        // the user passed on the command line. Mirrors Swift's
        // behaviour where `args[0]` is the executable/script identifier.
        let scriptArgs: [String]

        switch args[1] {
        case "-e":
            guard args.count >= 3 else { usage() }
            source = args[2]
            fileName = "<expression>"
            isInline = true
            scriptArgs = ["<expression>"] + Array(args.dropFirst(3))
        case "-h", "--help":
            usage()
        default:
            let url = URL(fileURLWithPath: args[1])
            do {
                var contents = try String(contentsOf: url, encoding: .utf8)
                // Honor `#!/usr/bin/env swift-script`-style shebangs by
                // rewriting them to a Swift line comment. We only swap
                // the leading `#!` (two chars) for `//` so byte offsets
                // and line numbers stay identical — diagnostics still
                // point at the right column.
                if contents.hasPrefix("#!") {
                    contents = "//" + contents.dropFirst(2)
                }
                source = contents
            } catch {
                Shell.current.stderr("error reading \(args[1]): \(error)\n")
                exit(1)
            }
            fileName = args[1]
            isInline = false
            scriptArgs = [args[1]] + Array(args.dropFirst(2))
        }

        let interpreter = Interpreter()
        // The interpreter binds `CommandLine.arguments` automatically
        // at eval time from `scriptArguments` (or, when that's empty,
        // from `Shell.current.scriptName` + `positionalParameters`).
        // The CLI just supplies argv here.
        interpreter.scriptArguments = scriptArgs

        do {
            // Inline `-e` keeps the legacy `eval(_:fileName:)` path so we
            // can print the resulting expression value. File scripts
            // route through `evalScript(_:fileName:)`, which converts
            // a thrown `ScriptExit` into the returned `ExitStatus`.
            if isInline {
                let result = try await interpreter.eval(source, fileName: fileName)
                if case .void = result {
                    // nothing to print
                } else {
                    Shell.current.stdout(result.description + "\n")
                }
                exit(0)
            } else {
                let status = try await interpreter.evalScript(
                    source, fileName: fileName)
                exit(status.code)
            }
        } catch let parseError as ParseError {
            interpreter.error(parseError.formatted)
            if !parseError.formatted.hasSuffix("\n") {
                interpreter.error("\n")
            }
            exit(1)
        } catch let scriptExit as ScriptExit {
            // Inline `-e` path: a script-side `exit(N)` still needs
            // to translate into the host's exit code.
            exit(scriptExit.status.code)
        } catch {
            // Runtime errors get the same caret-style rendering as
            // parse errors when the error carries source-location info.
            interpreter.error(interpreter.renderRuntimeError(error))
            exit(1)
        }
    }
}
