// The goldens are captured from **macOS** stock `swift`
// (`Tools/regen-probe-expectations.sh`), and several probes exercise
// Apple-Foundation-only behaviour (regex `range(of:options:)`,
// CharacterSet set-algebra the scl extractor doesn't surface). On
// swift-corelibs-foundation those bridges are correctly Darwin-gated
// and stock Swift itself can diverge, so the golden comparison is
// only meaningful on Darwin. Cross-platform *build* is covered by the
// build jobs; a Linux golden set would have to be captured on Linux
// (out of scope here).
#if canImport(Darwin)
import Testing
import Foundation
import ShellKit
@testable import SwiftScriptInterpreter

/// Conformance harness for issue #8: every probe script under
/// `Examples/llm_probes/` runs through the interpreter and its
/// stdout must match the checked-in golden produced by **stock**
/// `swift` (`Tools/regen-probe-expectations.sh`). A missing bridge
/// fails loudly and names the symbol; what this suite catches is the
/// worse failure mode — plausible output that silently disagrees
/// with stock Swift.
@Suite("Probe conformance (stock-Swift goldens)")
struct ProbeConformanceTests {

    private static var probesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SwiftScriptInterpreterTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Examples/llm_probes", isDirectory: true)
    }

    static var probeNames: [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: probesDirectory.path)) ?? []
        return entries
            .filter { $0.hasSuffix(".swift") }
            .map { String($0.dropLast(".swift".count)) }
            .sorted()
    }

    @Test(arguments: probeNames)
    func probeMatchesStockSwift(_ name: String) async throws {
        let dir = Self.probesDirectory
        let source = try String(
            contentsOf: dir.appendingPathComponent("\(name).swift"),
            encoding: .utf8)
        // Every probe must carry a golden — a probe without one
        // proves nothing about conformance.
        let expectedURL = dir.appendingPathComponent("expected/\(name).out")
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)

        let shell = TestShell()
        try await shell.shellKit.withCurrent {
            let interp = Interpreter()
            _ = try await interp.eval(source, fileName: "\(name).swift")
        }
        let normalizedOut = shell.stdout
            .replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedExpected = expected
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(
            normalizedOut == normalizedExpected,
            "probe \(name) diverged from stock Swift")
    }
}
#endif
