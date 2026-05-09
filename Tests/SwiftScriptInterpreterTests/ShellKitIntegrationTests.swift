import Testing
import Foundation
import ShellKit
@testable import SwiftScriptInterpreter

/// Disambiguate against `Testing.ExitStatus` (added by Swift Testing
/// 1743+ for exit-test assertions). We mean the ShellKit type.
typealias ExitStatus = ShellKit.ExitStatus

/// Tests that exercise the SwiftScript ↔ ShellKit boundary. Each
/// constructs a ``ShellKit/Shell`` with custom sinks / sandbox /
/// hostInfo, binds it for the test scope via `withCurrent(_:)`, and
/// asserts that script-side I/O routes through the bound surface.
@Suite("ShellKit integration")
struct ShellKitIntegrationTests {

    // MARK: stdout / stderr

    @Test func defaultOutputRoutesToShellCurrentStdout() async throws {
        let shell = TestShell()
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"print("hello")"#)
        }
        #expect(shell.stdout == "hello\n")
        #expect(shell.stderr == "")
    }

    @Test func printTerminatorEmptyDoesNotLeakToHostStdout() async throws {
        // Earlier versions short-circuited around `output` for any
        // non-`\n` terminator and called `Swift.print` directly,
        // bypassing the bound shell. This exercises the fix.
        let shell = TestShell()
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"""
                print("a", terminator: "|")
                print("b", terminator: "|")
                print("c", terminator: "")
                """#)
        }
        #expect(shell.stdout == "a|b|c")
    }

    @Test func parseErrorRoutesToShellCurrentStderr() async throws {
        let shell = TestShell()
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"let x = ###"#)
                Issue.record("expected ParseError")
            } catch let parseError as ParseError {
                interp.error(parseError.formatted)
            }
        }
        #expect(shell.stdout == "")
        #expect(shell.stderr.contains("error:"))
    }

    // MARK: stdin

    @Test func readLinePullsFromShellCurrentStdin() async throws {
        let shell = TestShell(
            stdin: .string("first line\nsecond line\n"))
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"""
                if let a = readLine(), let b = readLine() {
                    print(a + "+" + b)
                }
                """#)
        }
        #expect(shell.stdout == "first line+second line\n")
    }

    // MARK: CommandLine.arguments

    @Test func commandLineArgumentsReadFromBoundShell() async throws {
        let shell = TestShell()
        shell.shellKit.scriptName = "/abs/script.swift"
        shell.shellKit.positionalParameters = ["alpha", "beta"]
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"""
                for a in CommandLine.arguments {
                    print(a)
                }
                """#)
        }
        let lines = shell.stdout.split(separator: "\n").map(String.init)
        #expect(lines == ["/abs/script.swift", "alpha", "beta"])
    }

    @Test func explicitScriptArgumentsOverrideBoundShell() async throws {
        // When `interpreter.scriptArguments` is set explicitly, it
        // wins over the bound shell. Embedders that want to inject a
        // fixed argv (tests, replay) use this path.
        let shell = TestShell()
        shell.shellKit.scriptName = "/should/be/overridden"
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            interp.scriptArguments = ["/explicit", "x", "y"]
            try await interp.eval(#"""
                print(CommandLine.arguments[0])
                print(CommandLine.arguments[1])
                print(CommandLine.arguments[2])
                """#)
        }
        #expect(shell.stdout == "/explicit\nx\ny\n")
    }

    // MARK: exit / evalScript

    @Test func evalScriptCatchesExitAndReturnsStatus() async throws {
        let shell = TestShell()
        let status = try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.evalScript(#"""
                print("before")
                exit(42)
                print("after")
                """#)
        }
        #expect(status.code == 42)
        #expect(shell.stdout == "before\n")
    }

    @Test func evalLetsScriptExitPropagateForCallers() async throws {
        // Callers that use the value-returning `eval` path see
        // `ScriptExit` as a thrown error — they choose how to
        // surface it. This test exercises that boundary.
        let shell = TestShell()
        var caught: ExitStatus? = nil
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"exit(7)"#)
            } catch let scriptExit as ScriptExit {
                caught = scriptExit.status
            }
        }
        #expect(caught?.code == 7)
    }

    @Test func abortReturnsConventionalExitCode() async throws {
        let shell = TestShell()
        let status = try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.evalScript(#"abort()"#)
        }
        // Conventional 128 + SIGABRT (6) on Unix.
        #expect(status.code == 134)
        _ = shell  // silence unused-let warning
    }

    // MARK: sandbox — file-system gate

    @Test func sandboxBlocksReadOutsideAllowedRoot() async throws {
        // `fileExists` is gated for `.read`; the sandbox denies an
        // off-root path; the bridge wraps the denial as a thrown
        // user-side error.
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let outside = "/etc/passwd"
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    FileManager.default.fileExists(atPath: "\#(outside)")
                    """#)
            } catch {
                caughtError = error
            }
        }
        // We expect a UserThrowSignal wrapping a Sandbox.Denial. The
        // signal's payload is opaque; just confirm the right shape.
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal {
            if case .opaque(_, let payload) = signal.value,
               payload is ShellKit.Sandbox.Denial
            {
                // ok
            } else {
                Issue.record("expected Sandbox.Denial payload, got \(signal.value)")
            }
        } else {
            Issue.record("expected UserThrowSignal, got \(caughtError as Any)")
        }
    }

    @Test func sandboxAllowsAccessInsideAllowedRoot() async throws {
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Drop a sentinel file the script can stat.
        let sentinel = root + "/marker"
        try "x".write(toFile: sentinel, atomically: true, encoding: .utf8)

        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                                 allowedHosts: []))
        let escaped = sentinel.replacingOccurrences(of: "\\", with: "\\\\")
        let r = try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                FileManager.default.fileExists(atPath: "\#(escaped)")
                """#)
        }
        #expect(r == .bool(true))
    }

    // MARK: sandbox — FileHandle path inits

    @Test func sandboxBlocksFileHandleReadingAtPathOutsideRoot() async throws {
        // FileHandle(forReadingAtPath:) is the canonical "open a file"
        // door outside FileManager. Without the new gate it bypassed
        // the sandbox entirely.
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    FileHandle(forReadingAtPath: "/etc/passwd")
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is ShellKit.Sandbox.Denial
        {
            // ok
        } else {
            Issue.record("expected Sandbox.Denial, got \(caughtError as Any)")
        }
    }

    @Test func sandboxBlocksFileHandleWritingAtPathOutsideRoot() async throws {
        // The forWritingAtPath / forUpdatingAtPath inits gate as
        // `.write` so a sandbox that allows read but not write also
        // denies them. Validates the read-vs-write intent split.
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    FileHandle(forWritingAtPath: "/etc/passwd")
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is ShellKit.Sandbox.Denial
        {
            // ok
        } else {
            Issue.record("expected Sandbox.Denial, got \(caughtError as Any)")
        }
    }

    @Test func sandboxAllowsFileHandleReadingInsideRoot() async throws {
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sentinel = root + "/marker"
        try "hello".write(toFile: sentinel, atomically: true, encoding: .utf8)
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        let escaped = sentinel.replacingOccurrences(of: "\\", with: "\\\\")
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            // The init returns an Optional<FileHandle>; presence in the
            // result confirms the gate let it through and the open
            // succeeded.
            let r = try await interp.eval(#"""
                import Foundation
                let h = FileHandle(forReadingAtPath: "\#(escaped)")
                h != nil
                """#)
            #expect(r == .bool(true))
        }
    }

    // MARK: sandbox — Bundle path init

    @Test func sandboxBlocksBundlePathOutsideRoot() async throws {
        // Bundle(path:) opens a bundle root the script later reads
        // resources from. The gate fires at construction so a
        // pathological root (`/etc`) is denied before the script can
        // call .url(forResource:withExtension:).
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    Bundle(path: "/etc")
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is ShellKit.Sandbox.Denial
        {
            // ok
        } else {
            Issue.record("expected Sandbox.Denial, got \(caughtError as Any)")
        }
    }

    // MARK: sandbox — InputStream / OutputStream path inits

    @Test func sandboxBlocksOutputStreamWriteOutsideRoot() async throws {
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    OutputStream(toFileAtPath: "/etc/secrets", append: false)
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is ShellKit.Sandbox.Denial
        {
            // ok
        } else {
            Issue.record("expected Sandbox.Denial, got \(caughtError as Any)")
        }
    }

    // MARK: sandbox — FileWrapper URL methods

    // `Foundation.FileWrapper` is only bridged on Darwin (the type
    // is `@available(*, unavailable)` on swift-corelibs-foundation),
    // so this test only runs there.
    #if canImport(Darwin)
    @Test func sandboxBlocksFileWrapperMatchesContentsOutsideRoot() async throws {
        // FileWrapper.matchesContents(of:) reads filesystem state at
        // the supplied URL to decide if the wrapper still matches. The
        // `of:` label isn't in the generic urlLabelsRead set (too
        // collision-prone across Foundation), so the FileWrapper
        // receiver branch positionally gates index 0. Without that
        // gate, a script could construct an in-memory FileWrapper and
        // probe arbitrary host paths via matchesContents.
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    let w = FileWrapper(regularFileWithContents: Data())
                    w.matchesContents(of: URL(fileURLWithPath: "/etc/passwd"))
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is ShellKit.Sandbox.Denial
        {
            // ok
        } else {
            Issue.record("expected Sandbox.Denial, got \(caughtError as Any)")
        }
    }
    #endif

    // MARK: sandbox — Process deny

    // `Foundation.Process` is unavailable on the iOS family (iOS,
    // tvOS, watchOS, visionOS), so these tests only run where the
    // type exists.
    #if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
    @Test func sandboxDeniesProcessConstructionEntirely() async throws {
        // Foundation.Process spawns a real OS subprocess that escapes
        // every host gate, so the policy is "denied entirely whenever
        // a sandbox is bound". Even constructing a Process — without
        // calling .run() — has to fail so the script can't capture the
        // instance and pass it around.
        let root = NSTemporaryDirectory()
            + "swiftscript-sandbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shell = TestShell(
            sandbox: .rooted(at: URL(fileURLWithPath: root),
                             allowedHosts: []))
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    Process()
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is ProcessSandboxDenied
        {
            // ok
        } else {
            Issue.record("expected ProcessSandboxDenied, got \(caughtError as Any)")
        }
    }

    @Test func processConstructionAllowedWithoutSandbox() async throws {
        // Without a bound sandbox the deny check is a no-op, so the
        // standalone `swift-script` CLI behaves as before. Construct
        // a Process and check it boxes — we don't `.run()` it because
        // CI environments shouldn't fork test-time subprocesses.
        let shell = TestShell()  // no sandbox
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            let r = try await interp.eval(#"""
                import Foundation
                let p = Process()
                p.isRunning
                """#)
            #expect(r == .bool(false))
        }
    }
    #endif

    // MARK: network — URLRequest variants gate

    @Test func networkConfigBlocksURLSessionDataForRequestOffAllowList() async throws {
        // URLSession.data(for: URLRequest) was the headline hole the
        // generalised gate closes — the request-bearing overload now
        // pulls URL+method out of the URLRequest and runs them through
        // `authorizeURL` the same as the bare-URL overload.
        let net = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET])
        let shell = TestShell(networkConfig: net)
        var caughtError: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    let url = URL(string: "https://denied.example.com/secret")!
                    let req = URLRequest(url: url, timeoutInterval: 30.0)
                    try await URLSession.shared.upload(for: req, fromFile: url)
                    """#)
            } catch {
                caughtError = error
            }
        }
        #expect(caughtError != nil)
        if let signal = caughtError as? UserThrowSignal,
           case .opaque(_, let payload) = signal.value,
           payload is NetworkConfig.NetworkAccessDenied
        {
            // ok
        } else {
            Issue.record(
                "expected NetworkAccessDenied, got \(caughtError as Any)")
        }
    }

    @Test func networkConfigRejectsUnknownHTTPMethod() throws {
        // Earlier `NetworkConfig.checkAllowed` fell back to `.GET`
        // when `HTTPMethod(rawValue:)` returned nil, so a request
        // with `httpMethod = "FOO"` would be evaluated against GET
        // permissions and could pass when only GET was allowed —
        // even though the actual method stayed `FOO`. The fix is in
        // the helper itself; URLRequest's `httpMethod` setter isn't
        // bridged (it's a struct, the bridge generator only emits
        // setters for class-typed receivers), so this is a direct
        // unit test on the gate rather than through a script.
        let net = NetworkConfig(
            allowedURLPrefixes: [AllowedURLEntry("https://allowed.example.com")],
            allowedMethods: [.GET, .POST, .PUT, .DELETE, .HEAD, .PATCH, .OPTIONS])
        let url = URL(string: "https://allowed.example.com/x")!
        do {
            try net.checkAllowed(url: url, method: "FOO")
            Issue.record("expected NetworkAccessDenied for unknown method")
        } catch let denial as NetworkConfig.NetworkAccessDenied {
            #expect(denial.reason.contains("FOO not supported"),
                    "got: \(denial.reason)")
        } catch {
            Issue.record("expected NetworkAccessDenied, got \(error)")
        }
    }

    // MARK: identity

    @Test func processInfoUserNameReadsHostInfo() async throws {
        var info = HostInfo.synthetic
        info.userName = "sandbox-user"
        info.hostName = "sandbox-host"
        let shell = TestShell(hostInfo: info)
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"""
                import Foundation
                print(ProcessInfo.processInfo.userName)
                print(ProcessInfo.processInfo.hostName)
                """#)
        }
        #expect(shell.stdout == "sandbox-user\nsandbox-host\n")
    }

    @Test func processInfoArgumentsMirrorsCommandLine() async throws {
        let shell = TestShell()
        shell.shellKit.scriptName = "myscript.swift"
        shell.shellKit.positionalParameters = ["one", "two"]
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"""
                import Foundation
                for a in ProcessInfo.processInfo.arguments {
                    print(a)
                }
                """#)
        }
        let lines = shell.stdout.split(separator: "\n").map(String.init)
        #expect(lines == ["myscript.swift", "one", "two"])
    }

    @Test func processInfoEnvironmentReadsBoundEnvironment() async throws {
        let shell = TestShell()
        shell.shellKit.environment.variables = ["FOO": "bar", "BAZ": "qux"]
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            try await interp.eval(#"""
                import Foundation
                let env = ProcessInfo.processInfo.environment
                print(env["FOO"] ?? "")
                print(env["BAZ"] ?? "")
                """#)
        }
        #expect(shell.stdout == "bar\nqux\n")
    }
}

// MARK: - Test harness

/// A `ShellKit.Shell` wired up with capturing stdio sinks plus
/// optional `stdin` / `sandbox` / `hostInfo` / `networkConfig`. The
/// tests bind it via `shellKit.withCurrent { … }` for the duration
/// of each script evaluation.
final class TestShell {
    let shellKit: ShellKit.Shell
    private let stdoutBox = StringBox()
    private let stderrBox = StringBox()
    var stdout: String { stdoutBox.read() }
    var stderr: String { stderrBox.read() }

    init(stdin: InputSource = .empty,
         sandbox: ShellKit.Sandbox? = nil,
         hostInfo: HostInfo = .synthetic,
         networkConfig: NetworkConfig? = nil)
    {
        let stdoutBox = self.stdoutBox
        let stderrBox = self.stderrBox
        self.shellKit = ShellKit.Shell(
            stdin: stdin,
            stdout: OutputSink(onWrite: { stdoutBox.append($0) }),
            stderr: OutputSink(onWrite: { stderrBox.append($0) }),
            environment: Environment(),
            sandbox: sandbox,
            networkConfig: networkConfig,
            hostInfo: hostInfo)
    }

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ data: Data) {
            let s = String(decoding: data, as: UTF8.self)
            lock.lock(); defer { lock.unlock() }
            value.append(s)
        }
        func read() -> String {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
