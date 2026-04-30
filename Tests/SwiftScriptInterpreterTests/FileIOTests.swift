import Testing
import Foundation
@testable import SwiftScriptInterpreter

@Suite("File I/O")
struct FileIOTests {
    /// Escape backslashes so a Windows path (`C:\Users\...`) is safe to
    /// embed inside a Swift string literal in the script under test —
    /// otherwise the interpreter's parser reads `\U` as an escape
    /// sequence and rejects the literal.
    private static func swiftLiteralEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
    }

    @Test func fileExistsTrue() async throws {
        let interp = Interpreter()
        let tempDir = Self.swiftLiteralEscape(NSTemporaryDirectory())
        let r = try await interp.eval(#"""
            import Foundation
            FileManager.default.fileExists(atPath: "\#(tempDir)")
            """#)
        #expect(r == .bool(true))
    }

    @Test func fileExistsFalse() async throws {
        let interp = Interpreter()
        let missing = Self.swiftLiteralEscape(
            NSTemporaryDirectory() + "__definitely-does-not-exist__")
        let r = try await interp.eval(#"""
            import Foundation
            FileManager.default.fileExists(atPath: "\#(missing)")
            """#)
        #expect(r == .bool(false))
    }

    @Test func roundTripReadWriteRemove() async throws {
        let interp = Interpreter()
        // Pick a temp path and clean up at the end.
        let tempPath = NSTemporaryDirectory() + "swiftscript_test_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let escaped = Self.swiftLiteralEscape(tempPath)
        let r = try await interp.eval(#"""
            import Foundation
            let path = "\#(escaped)"
            try "hello world".write(toFile: path, atomically: true, encoding: .utf8)
            let read = try String(contentsOfFile: path, encoding: .utf8)
            try FileManager.default.removeItem(atPath: path)
            (read, FileManager.default.fileExists(atPath: path))
            """#)
        #expect(r == .tuple([.string("hello world"), .bool(false)]))
    }

    @Test func contentsOfDirectory() async throws {
        // Drop a sentinel file into the temp directory and check that
        // contentsOfDirectory sees it. Avoids relying on a hardcoded
        // root path or well-known directory name (`/`, `/tmp`) that
        // doesn't exist on Windows.
        let interp = Interpreter()
        let dir = NSTemporaryDirectory()
        let sentinel = "swiftscript_dir_\(UUID().uuidString).marker"
        let path = dir + sentinel
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let escapedDir = Self.swiftLiteralEscape(dir)
        let r = try await interp.eval(#"""
            import Foundation
            try FileManager.default.contentsOfDirectory(atPath: "\#(escapedDir)").contains("\#(sentinel)")
            """#)
        #expect(r == .bool(true))
    }

    @Test func readMissingFileThrows() async throws {
        let interp = Interpreter()
        let missing = Self.swiftLiteralEscape(
            NSTemporaryDirectory() + "__nope_\(UUID().uuidString)__.txt")
        await #expect(throws: UserThrowSignal.self) {
            _ = try await interp.eval(#"""
                import Foundation
                try String(contentsOfFile: "\#(missing)", encoding: .utf8)
                """#)
        }
    }

    @Test func tryQuestionMarkOnFailure() async throws {
        let interp = Interpreter()
        let missing = Self.swiftLiteralEscape(
            NSTemporaryDirectory() + "__nope_\(UUID().uuidString)__.txt")
        let r = try await interp.eval(#"""
            import Foundation
            try? String(contentsOfFile: "\#(missing)", encoding: .utf8)
            """#)
        #expect(r == .optional(nil))
    }
}
