import Testing
import Foundation
import ShellKit
@testable import SwiftScriptInterpreter

/// Tests for the `import Subprocess` bridge in SwiftScript. Each
/// installs a recording ``ProcessLauncher`` on the bound shell so the
/// tests don't depend on the host filesystem; one platform-gated test
/// at the end exercises the standalone path through real exec via
/// `DefaultProcessLauncher`.
@Suite("Subprocess bridge")
struct SubprocessBridgeTests {

    // MARK: Dispatch routing

    @Test func runRoutesThroughBoundProcessLauncher() async throws {
        let launcher = RecordingLauncher(stubStdout: "captured\n")
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Subprocess
                let r = try await Subprocess.run(
                    Executable.name("any-name"),
                    arguments: ["a", "b"],
                    output: Output.string(limit: 4096))
                """#)
        }
        #expect(launcher.lastExecutableDescription == "any-name")
        #expect(launcher.lastArguments == ["a", "b"])
    }

    @Test func executablePathPassesThroughVerbatim() async throws {
        let launcher = RecordingLauncher()
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Subprocess
                _ = try await Subprocess.run(
                    Executable.path("/usr/local/bin/myprog"),
                    arguments: [],
                    output: Output.discarded)
                """#)
        }
        #expect(launcher.lastExecutableDescription == "/usr/local/bin/myprog")
    }

    // MARK: Output capture

    @Test func outputStringCapturesStdoutToStandardOutput() async throws {
        let launcher = RecordingLauncher(stubStdout: "hi\n")
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("greet"),
                    arguments: [],
                    output: Output.string(limit: 4096))
                result.standardOutput
                """#)
            #expect(r == .optional(.string("hi\n")))
        }
    }

    @Test func outputStringPreservesEmptyCaptureAsEmptyString() async throws {
        // `.string(limit:)` with zero captured bytes returns
        // `Optional("")` — distinct from `nil` for `.discarded`. Lets
        // a script tell a silent command apart from a discarded
        // stream.
        let launcher = RecordingLauncher(stubStdout: "")
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("silent"),
                    arguments: [],
                    output: Output.string(limit: 4096))
                result.standardOutput
                """#)
            #expect(r == .optional(.string("")))
        }
    }

    @Test func outputStringThrowsOnLimitOverflow() async throws {
        // `.string(limit: N)` is documented to throw if emitted bytes
        // exceed N — silently truncating would hand the script
        // partial data with no way to detect the loss. Configure a
        // launcher that produces 50 bytes against a 10-byte limit and
        // verify the bridge surfaces the overflow as an error.
        let launcher = RecordingLauncher(stubStdout: String(repeating: "x", count: 50))
        let shell = TestShell(launcher: launcher)
        var caught: String?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Subprocess
                    _ = try await Subprocess.run(
                        Executable.name("noisy"),
                        arguments: [],
                        output: Output.string(limit: 10))
                    """#)
            } catch {
                caught = String(describing: error)
            }
        }
        #expect(caught != nil)
        #expect(caught?.contains("standardOutput") == true)
        #expect(caught?.contains("10 bytes") == true)
    }

    @Test func errorStringThrowsOnLimitOverflow() async throws {
        // Same overflow contract on the stderr side.
        let launcher = RecordingLauncher(stubStderr: String(repeating: "y", count: 100))
        let shell = TestShell(launcher: launcher)
        var caught: String?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Subprocess
                    _ = try await Subprocess.run(
                        Executable.name("noisy"),
                        arguments: [],
                        output: Output.discarded,
                        error: ErrorOutput.string(limit: 5))
                    """#)
            } catch {
                caught = String(describing: error)
            }
        }
        #expect(caught != nil)
        #expect(caught?.contains("standardError") == true)
    }

    @Test func outputDiscardedReturnsNil() async throws {
        let launcher = RecordingLauncher(stubStdout: "ignored\n")
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("greet"),
                    arguments: [],
                    output: Output.discarded)
                result.standardOutput
                """#)
            // `.discarded` skips the buffer, the launcher's stub
            // bytes never make it back into the script-visible
            // record.
            #expect(r == .optional(nil))
        }
    }

    @Test func errorStringCapturesStderr() async throws {
        let launcher = RecordingLauncher(stubStderr: "boom\n")
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("noisy"),
                    arguments: [],
                    output: Output.discarded,
                    error: ErrorOutput.string(limit: 4096))
                result.standardError
                """#)
            #expect(r == .optional(.string("boom\n")))
        }
    }

    // MARK: TerminationStatus

    @Test func terminationStatusIsSuccessForExitZero() async throws {
        let launcher = RecordingLauncher(termination: .exited(0))
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("ok"), arguments: [], output: Output.discarded)
                result.terminationStatus.isSuccess
                """#)
            #expect(r == .bool(true))
        }
    }

    @Test func terminationStatusExitedCodeForNonZero() async throws {
        let launcher = RecordingLauncher(termination: .exited(7))
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("rc"), arguments: [], output: Output.discarded)
                result.terminationStatus.exitedCode
                """#)
            #expect(r == .optional(.int(7)))
        }
    }

    @Test func terminationStatusSignaledCodeForSignaled() async throws {
        let launcher = RecordingLauncher(termination: .signaled(15))
        let shell = TestShell(launcher: launcher)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.name("term"), arguments: [], output: Output.discarded)
                (result.terminationStatus.signaledCode, result.terminationStatus.exitedCode)
                """#)
            #expect(r == .tuple([.optional(.int(15)), .optional(nil)], labels: []))
        }
    }

    // MARK: Sandbox refusal

    @Test func sandboxedDenyLauncherSurfacesAsThrownError() async {
        let shell = TestShell(launcher: SandboxedDenyLauncher(reason: "no exec under test"))
        var caught: String?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Subprocess
                    _ = try await Subprocess.run(
                        Executable.name("anything"),
                        arguments: [],
                        output: Output.discarded)
                    """#)
            } catch {
                caught = String(describing: error)
            }
        }
        // The launcher's `ProcessLaunchDenied` propagates to the
        // script as an error — typed-error pattern matching against
        // ShellKit types is not available script-side, but the bridge
        // does not eat it either.
        #expect(caught != nil)
    }

    // MARK: Real-exec path (standalone)

    #if os(macOS) || os(Linux)
    @Test func standalonePathDelegatesToRealExec() async throws {
        // The default shell uses `DefaultProcessLauncher`, which goes
        // through `swift-subprocess.run(...)` to the real OS. Confirms
        // the bridge plumbs all the way through end-to-end on
        // platforms where real exec is available.
        let shell = TestShell()  // default launcher
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Subprocess
                let result = try await Subprocess.run(
                    Executable.path("/bin/echo"),
                    arguments: ["hi"],
                    output: Output.string(limit: 4096))
                result.standardOutput
                """#)
            #expect(r == .optional(.string("hi\n")))
        }
    }
    #endif
}

// MARK: - Recording launcher

private final class RecordingLauncher: ProcessLauncher, @unchecked Sendable {
    private let stubStdout: Data
    private let stubStderr: Data
    private let termination: TerminationStatus

    // Plain stored properties — every test runs the launcher from a
    // single Task, so the cross-task coordination NSLock would buy
    // is unneeded. `@unchecked Sendable` advertises that.
    var lastExecutableDescription: String?
    var lastArguments: [String]?

    init(
        stubStdout: String = "",
        stubStderr: String = "",
        termination: TerminationStatus = .exited(0)
    ) {
        self.stubStdout = Data(stubStdout.utf8)
        self.stubStderr = Data(stubStderr.utf8)
        self.termination = termination
    }

    func launch(
        _ executable: Executable,
        arguments: Arguments,
        environment: Environment,
        workingDirectory: String?,
        input: InputSource,
        output: OutputSink,
        error: OutputSink
    ) async throws -> ExecutionRecord {
        lastExecutableDescription = executable.description
        lastArguments = arguments.values

        if !stubStdout.isEmpty { output.write(stubStdout) }
        if !stubStderr.isEmpty { error.write(stubStderr) }

        return ExecutionRecord(
            processIdentifier: 999,
            terminationStatus: termination,
            standardOutput: stubStdout,
            standardError: stubStderr)
    }
}

// MARK: - TestShell variant that takes a launcher

private extension TestShell {
    convenience init(launcher: any ProcessLauncher) {
        self.init()
        self.shellKit.processLauncher = launcher
    }
}
