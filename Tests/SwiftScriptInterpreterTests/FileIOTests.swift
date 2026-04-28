import Testing
import Foundation
@testable import SwiftScriptInterpreter

@Suite("File I/O")
struct FileIOTests {
    @Test func fileExistsTrue() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            FileManager.default.fileExists(atPath: "/tmp")
            """#)
        #expect(r == .bool(true))
    }

    @Test func fileExistsFalse() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            FileManager.default.fileExists(atPath: "/tmp/__definitely-does-not-exist__")
            """#)
        #expect(r == .bool(false))
    }

    @Test func roundTripReadWriteRemove() async throws {
        let interp = Interpreter()
        // Pick a temp path and clean up at the end.
        let tempPath = NSTemporaryDirectory() + "swiftscript_test_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let r = try await interp.eval(#"""
            import Foundation
            let path = "\#(tempPath)"
            try "hello world".write(toFile: path, atomically: true, encoding: .utf8)
            let read = try String(contentsOfFile: path, encoding: .utf8)
            try FileManager.default.removeItem(atPath: path)
            (read, FileManager.default.fileExists(atPath: path))
            """#)
        #expect(r == .tuple([.string("hello world"), .bool(false)]))
    }

    @Test func contentsOfDirectory() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            try FileManager.default.contentsOfDirectory(atPath: "/").contains("tmp")
            """#)
        #expect(r == .bool(true))
    }

    @Test func readMissingFileThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: UserThrowSignal.self) {
            _ = try await interp.eval(#"""
                import Foundation
                try String(contentsOfFile: "/__nope__.txt", encoding: .utf8)
                """#)
        }
    }

    @Test func tryQuestionMarkOnFailure() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            try? String(contentsOfFile: "/__nope__.txt", encoding: .utf8)
            """#)
        #expect(r == .optional(nil))
    }
}
