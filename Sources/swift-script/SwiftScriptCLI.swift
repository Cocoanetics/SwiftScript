import Foundation
import SwiftScriptInterpreter

/// CLI entry. Wrapped in a `@main` struct (rather than top-level code)
/// so `main()` is nonisolated — top-level code becomes implicitly
/// `@MainActor`-isolated under Swift 6 strict concurrency, which makes
/// the `try await interpreter.eval(...)` call cross an actor boundary
/// and trip on `Value` not being `Sendable`. Keeping `main` nonisolated
/// matches where the interpreter actually runs.
@main
struct SwiftScriptCLI {
    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
            usage: swift-script <file.swift>
                   swift-script -e <expression>

            """.utf8))
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
                FileHandle.standardError.write(Data("error reading \(args[1]): \(error)\n".utf8))
                exit(1)
            }
            fileName = args[1]
            isInline = false
            scriptArgs = [args[1]] + Array(args.dropFirst(2))
        }

        let interpreter = Interpreter()
        interpreter.scriptArguments = scriptArgs
        // Surface `CommandLine.arguments` to the script. Registered here
        // (rather than as part of the always-on stdlib bridges) because
        // the argv list comes from the host's CLI parsing and isn't
        // known at interpreter-init time. Static-let semantics is fine —
        // script argv is fixed for the lifetime of one run.
        interpreter.bridges["static let CommandLine.arguments"] =
            .staticValue(.array(scriptArgs.map { .string($0) }))

        do {
            let result = try await interpreter.eval(source, fileName: fileName)
            if isInline, case .void = result {
                // nothing to print
            } else if isInline {
                print(result.description)
            }
        } catch let parseError as ParseError {
            FileHandle.standardError.write(Data(parseError.formatted.utf8))
            if !parseError.formatted.hasSuffix("\n") {
                FileHandle.standardError.write(Data("\n".utf8))
            }
            exit(1)
        } catch {
            // Runtime errors get the same caret-style rendering as
            // parse errors when the error carries source-location info.
            FileHandle.standardError.write(Data(interpreter.renderRuntimeError(error).utf8))
            exit(1)
        }
    }
}
