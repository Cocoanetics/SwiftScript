import Testing
import Foundation
import ShellKit
@testable import SwiftScriptInterpreter

/// The SwiftBash#83 contract at the SwiftScript level: one
/// ``PathMapping`` drives both the virtual→host translation
/// (`Shell.resolve`, consumed via `authorizePath`'s return) and the
/// confinement gate (`Sandbox.confined(to:)`), so a script that
/// spells `/tmp/x` reads and writes the per-instance host directory
/// backing `/tmp` — and never the host's shared `/tmp`, never any
/// host spelling at all.
@Suite("Confined sandbox (PathMapping)")
struct ConfinedSandboxTests {

    /// Two real host dirs behind a two-mount virtual namespace —
    /// the same layout `swift-bash exec --sandbox` builds.
    private struct Fixture {
        let workspace: URL   // backs /batch
        let temp: URL        // backs /tmp
        let shell: TestShell

        init() throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swiftscript-confined-\(UUID().uuidString)")
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            temp = root.appendingPathComponent("temp", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: temp, withIntermediateDirectories: true)
            let mapping = PathMapping(mounts: [
                .init(virtual: "/batch", host: workspace.path),
                .init(virtual: "/tmp", host: temp.path),
            ])
            shell = TestShell(sandbox: .confined(to: mapping, home: "/batch"))
            shell.shellKit.environment.workingDirectory = "/batch"
            shell.shellKit.environment.variables["HOME"] = "/batch"
            shell.shellKit.environment.variables["TMPDIR"] = "/tmp"
        }

        func tearDown() {
            try? FileManager.default.removeItem(
                at: workspace.deletingLastPathComponent())
        }
    }

    /// Escape backslashes so a host path can sit inside a script
    /// string literal on Windows.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
    }

    /// Run `source` in the fixture's shell and expect a
    /// `Sandbox.Denial` surfaced as a `UserThrowSignal`.
    private func expectDenial(
        _ fixture: Fixture,
        _ source: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var caught: Error?
        await fixture.shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(source)
            } catch {
                caught = error
            }
        }
        guard let signal = caught as? UserThrowSignal,
              case .opaque(_, let payload) = signal.value,
              payload is ShellKit.Sandbox.Denial
        else {
            Issue.record(
                "expected Sandbox.Denial, got \(String(describing: caught))",
                sourceLocation: sourceLocation)
            return
        }
    }

    // MARK: - Bytes land in the mapped host dirs

    @Test func virtualTmpWriteLandsInMappedHostDir() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Foundation
                try "hello mapped".write(toFile: "/tmp/x.txt", atomically: true, encoding: .utf8)
                """#)
        }
        // The bytes are in the per-instance host dir backing /tmp…
        let hostSide = try String(
            contentsOf: fx.temp.appendingPathComponent("x.txt"),
            encoding: .utf8)
        #expect(hostSide == "hello mapped")
        // …and the script reads them back under the virtual spelling.
        let readBack = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                try String(contentsOfFile: "/tmp/x.txt", encoding: .utf8)
                """#)
        }
        #expect(readBack == .string("hello mapped"))
    }

    @Test func relativePathsAnchorToVirtualCWD() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Foundation
                try "relative".write(toFile: "rel.txt", atomically: true, encoding: .utf8)
                """#)
        }
        // CWD is /batch, backed by the workspace dir — not the host
        // process CWD.
        let hostSide = try String(
            contentsOf: fx.workspace.appendingPathComponent("rel.txt"),
            encoding: .utf8)
        #expect(hostSide == "relative")
    }

    @Test func dataRoundTripsThroughURLDoor() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                let d = "payload".data(using: .utf8)!
                try d.write(to: URL(fileURLWithPath: "/tmp/d.bin"))
                let back = try Data(contentsOf: URL(fileURLWithPath: "/tmp/d.bin"))
                String(data: back, encoding: .utf8)!
                """#)
        }
        #expect(r == .string("payload"))
        #expect(FileManager.default.fileExists(
            atPath: fx.temp.appendingPathComponent("d.bin").path))
    }

    @Test func fileManagerDoorsTranslate() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        try "seed".write(
            to: fx.temp.appendingPathComponent("seed.txt"),
            atomically: true, encoding: .utf8)
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                let fm = FileManager.default
                let existed = fm.fileExists(atPath: "/tmp/seed.txt")
                try fm.createDirectory(atPath: "/tmp/sub", withIntermediateDirectories: true)
                let listing = try fm.contentsOfDirectory(atPath: "/tmp")
                try fm.removeItem(atPath: "/tmp/seed.txt")
                let gone = !fm.fileExists(atPath: "/tmp/seed.txt")
                (existed, listing.sorted().joined(separator: ","), gone)
                """#)
        }
        #expect(r == .tuple([.bool(true), .string("seed.txt,sub"), .bool(true)]))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: fx.temp.appendingPathComponent("sub").path,
            isDirectory: &isDir) && isDir.boolValue)
        #expect(!FileManager.default.fileExists(
            atPath: fx.temp.appendingPathComponent("seed.txt").path))
    }

    @Test func fileHandleOpensTranslatedPath() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        try "handle bytes".write(
            to: fx.temp.appendingPathComponent("h.txt"),
            atomically: true, encoding: .utf8)
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                FileHandle(forReadingAtPath: "/tmp/h.txt") != nil
                """#)
        }
        #expect(r == .bool(true))
    }

    // MARK: - Virtual cd

    @Test func changeCurrentDirectoryPathIsVirtual() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        let hostCWDBefore = FileManager.default.currentDirectoryPath
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                let fm = FileManager.default
                let ok = fm.changeCurrentDirectoryPath("/tmp")
                try "moved".write(toFile: "after-cd.txt", atomically: true, encoding: .utf8)
                (ok, fm.currentDirectoryPath)
                """#)
        }
        #expect(r == .tuple([.bool(true), .string("/tmp")]))
        // The relative write followed the virtual cd into the /tmp
        // mount's host dir…
        let hostSide = try String(
            contentsOf: fx.temp.appendingPathComponent("after-cd.txt"),
            encoding: .utf8)
        #expect(hostSide == "moved")
        // …and the host process CWD never moved.
        #expect(FileManager.default.currentDirectoryPath == hostCWDBefore)
    }

    @Test func changeCurrentDirectoryPathToMissingDirFails() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                FileManager.default.changeCurrentDirectoryPath("/tmp/nope")
                """#)
        }
        #expect(r == .bool(false))
    }

    // MARK: - Denials

    @Test func readOutsideMountsIsDenied() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        await expectDenial(fx, #"""
            import Foundation
            try String(contentsOfFile: "/etc/passwd", encoding: .utf8)
            """#)
    }

    @Test func writeOutsideMountsIsDenied() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        await expectDenial(fx, #"""
            import Foundation
            try "leak".write(toFile: "/outside.txt", atomically: true, encoding: .utf8)
            """#)
    }

    @Test func hostSpellingOfMountedDirIsDenied() async throws {
        // Script-visible text is the only addressing scheme: holding
        // the *host* path of a mounted directory must not grant
        // access through the virtual namespace.
        //
        // This test deliberately uses a single `/work` mount rather
        // than the shared `/tmp` fixture: on Linux `NSTemporaryDirectory()`
        // *is* `/tmp`, so the host spelling of a `/tmp`-backed mount
        // starts with `/tmp` and would re-match the `/tmp` virtual
        // prefix instead of landing outside the namespace. Backing a
        // `/work` mount means the host spelling matches no mount on
        // either platform and voids. (SwiftBash's ConfinedSandboxTests
        // avoids a `/tmp` mount here for the same reason.)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftscript-hostspell-\(UUID().uuidString)")
        let workHost = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workHost, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "secret".write(
            to: workHost.appendingPathComponent("s.txt"),
            atomically: true, encoding: .utf8)
        let mapping = PathMapping(mounts: [
            .init(virtual: "/work", host: workHost.path),
        ])
        let shell = TestShell(sandbox: .confined(to: mapping, home: "/work"))
        shell.shellKit.environment.workingDirectory = "/work"
        let hostSpelling = Self.esc(workHost.appendingPathComponent("s.txt").path)

        var caught: Error?
        await shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval("""
                    import Foundation
                    try String(contentsOfFile: "\(hostSpelling)", encoding: .utf8)
                    """)
            } catch {
                caught = error
            }
        }
        guard let signal = caught as? UserThrowSignal,
              case .opaque(_, let payload) = signal.value,
              payload is ShellKit.Sandbox.Denial
        else {
            Issue.record("expected Sandbox.Denial, got \(String(describing: caught))")
            return
        }
        // The virtual spelling still works, proving the mount is live.
        let ok = try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                try String(contentsOfFile: "/work/s.txt", encoding: .utf8)
                """#)
        }
        #expect(ok == .string("secret"))
    }

    @Test func fileManagerProbeOutsideMountsIsDenied() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        await expectDenial(fx, #"""
            import Foundation
            FileManager.default.fileExists(atPath: "/etc")
            """#)
    }

    @Test func mountedVolumeTopologyNotDisclosed() async throws {
        // `FileManager.default.mountedVolumeURLs(...)` would hand a
        // confined script the whole host volume list. It must not be
        // a reachable bridge at all.
        let fx = try Fixture()
        defer { fx.tearDown() }
        var errorText = ""
        await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)
                    """#)
                Issue.record("mountedVolumeURLs should not be bridged")
            } catch let error as RuntimeError {
                errorText = "\(error)"
            } catch {
                errorText = "\(error)"
            }
        }
        #expect(errorText.contains("has no method") || errorText.contains("mountedVolumeURLs"))
        #expect(!errorText.contains("/Volumes"))
    }

    @Test func bundleStaticDirectoryEnumeratorsNotBridged() async throws {
        // `Bundle.paths(forResourcesOfType:inDirectory:)` reads an
        // arbitrary host directory passed as a "bundle path" with no
        // gate — it must not be a reachable bridge.
        let fx = try Fixture()
        defer { fx.tearDown() }
        var caught = false
        await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    Bundle.paths(forResourcesOfType: "txt", inDirectory: "/etc")
                    """#)
                Issue.record("Bundle.paths(...inDirectory:) should not be bridged")
            } catch {
                caught = true
            }
        }
        #expect(caught)
    }

    #if !os(Windows)
    @Test func symlinkEscapeIsDenied() async throws {
        // A link planted inside the mount pointing at the filesystem
        // root: translation follows the mount, canonicalisation
        // lands outside every host root, the gate denies.
        let fx = try Fixture()
        defer { fx.tearDown() }
        try FileManager.default.createSymbolicLink(
            at: fx.temp.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/"))
        await expectDenial(fx, #"""
            import Foundation
            try String(contentsOfFile: "/tmp/escape/etc/passwd", encoding: .utf8)
            """#)
    }
    #endif

    // MARK: - No host paths in script-visible answers

    @Test func temporaryDirectoryReportsVirtualSpelling() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                FileManager.default.temporaryDirectory.path
                """#)
        }
        #expect(r == .string("/tmp"))
    }

    @Test func scriptVisibleAnswersNeverCarryHostPaths() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Foundation
                let fm = FileManager.default
                print(fm.currentDirectoryPath)
                print(fm.temporaryDirectory.path)
                print(ProcessInfo.processInfo.environment["TMPDIR"] ?? "unset")
                """#)
        }
        let out = fx.shell.stdout
        #expect(out == "/batch\n/tmp\n/tmp\n")
        #expect(!out.contains(fx.workspace.path))
        #expect(!out.contains(fx.temp.path))
    }

    @Test func urlStaticsAndGlobalsStayVirtual() async throws {
        // The URL statics and NS* globals answer from the bound shell,
        // not from host values captured at bridge registration.
        let fx = try Fixture()
        defer { fx.tearDown() }
        try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Foundation
                print(URL.temporaryDirectory.path)
                print(URL.homeDirectory.path)
                print(URL.currentDirectory().path)
                print(NSTemporaryDirectory())
                print(NSHomeDirectory())
                """#)
        }
        let out = fx.shell.stdout
        #expect(out == "/tmp\n/batch\n/batch\n/tmp\n/batch\n")
        #expect(!out.contains(fx.workspace.path))
        #expect(!out.contains(fx.temp.path))
    }

    @Test func relativeFileURLWithNilBaseAnchorsToVirtualCWD() async throws {
        // `URL(fileURLWithPath: "rel", relativeTo: nil)` must anchor
        // to the shell's virtual CWD like the no-base init — not the
        // host process CWD — so the URL door and String door agree.
        let fx = try Fixture()
        defer { fx.tearDown() }
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                try "rel-nil-base".write(toFile: "viaString.txt", atomically: true, encoding: .utf8)
                let u = URL(fileURLWithPath: "viaString.txt", relativeTo: nil)
                let back = try Data(contentsOf: u)
                String(data: back, encoding: .utf8)!
                """#)
        }
        #expect(r == .string("rel-nil-base"))
        #expect(FileManager.default.fileExists(
            atPath: fx.workspace.appendingPathComponent("viaString.txt").path))
    }

    @Test func urlHomeDirectoryForUserNotReachable() async throws {
        // `URL.homeDirectory(forUser:)` reads the host account
        // database — it must not be a reachable bridge under a
        // sandbox (nor at all), like the blocked FileManager twin.
        let fx = try Fixture()
        defer { fx.tearDown() }
        var errored = false
        var out = ""
        await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    URL.homeDirectory(forUser: "root")
                    """#)
                Issue.record("URL.homeDirectory(forUser:) should not be bridged")
            } catch {
                errored = true
                out = "\(error)"
            }
        }
        #expect(errored)
        #expect(!out.contains("/Users"))
        #expect(!out.contains("/var"))
    }

    @Test func relativeFileURLDoorAgreesWithStringDoor() async throws {
        // `URL(fileURLWithPath: "rel")` anchors to the shell's logical
        // CWD, so the URL door and the String door name the same file.
        let fx = try Fixture()
        defer { fx.tearDown() }
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                try "same file".write(toFile: "agree.txt", atomically: true, encoding: .utf8)
                let viaURL = try Data(contentsOf: URL(fileURLWithPath: "agree.txt"))
                String(data: viaURL, encoding: .utf8)!
                """#)
        }
        #expect(r == .string("same file"))
        #expect(FileManager.default.fileExists(
            atPath: fx.workspace.appendingPathComponent("agree.txt").path))
    }

    @Test func emptyPathStaysAGuaranteedError() async throws {
        // Foundation rejects "" everywhere; resolving it to the CWD
        // would turn removeItem(atPath: "") into rm -rf of the working
        // directory. It must keep failing — and must not delete.
        let fx = try Fixture()
        defer { fx.tearDown() }
        try "canary".write(
            to: fx.workspace.appendingPathComponent("canary.txt"),
            atomically: true, encoding: .utf8)
        let r = try await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            return try await interp.eval(#"""
                import Foundation
                let existsEmpty = FileManager.default.fileExists(atPath: "")
                var removeFailed = false
                do {
                    try FileManager.default.removeItem(atPath: "")
                } catch {
                    removeFailed = true
                }
                (existsEmpty, removeFailed)
                """#)
        }
        #expect(r == .tuple([.bool(false), .bool(true)]))
        #expect(FileManager.default.fileExists(
            atPath: fx.workspace.appendingPathComponent("canary.txt").path))
    }

    @Test func denialDoesNotLeakHostPaths() async throws {
        let fx = try Fixture()
        defer { fx.tearDown() }
        var message = ""
        await fx.shell.shellKit.withCurrent {
            let interp = Interpreter()
            do {
                _ = try await interp.eval(#"""
                    import Foundation
                    try String(contentsOfFile: "/tmp/../secret", encoding: .utf8)
                    """#)
            } catch let signal as UserThrowSignal {
                if case .opaque(_, let payload) = signal.value,
                   let denial = payload as? ShellKit.Sandbox.Denial
                {
                    message = "\(denial)" + (denial.errorDescription ?? "")
                }
            } catch {
                Issue.record("expected UserThrowSignal, got \(error)")
            }
        }
        #expect(!message.isEmpty)
        #expect(!message.contains(fx.workspace.path))
        #expect(!message.contains(fx.temp.path))
    }

    // MARK: - Virtual CWD without a sandbox

    @Test func relativePathsHonourVirtualCWDWithoutSandbox() async throws {
        // An embedder that binds a working directory but no sandbox
        // still gets its CWD honoured — resolution and confinement
        // are separate concerns.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftscript-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = TestShell()
        shell.shellKit.environment.workingDirectory = dir.path
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(#"""
                import Foundation
                try "anchored".write(toFile: "anchor.txt", atomically: true, encoding: .utf8)
                """#)
        }
        let hostSide = try String(
            contentsOf: dir.appendingPathComponent("anchor.txt"),
            encoding: .utf8)
        #expect(hostSide == "anchored")
    }
}
