import Testing
import Foundation
@testable import SwiftScriptInterpreter

@Suite("Async / await")
struct AsyncTests {
    @Test func awaitOnBridgedSleepActuallySuspends() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        let start = Date()
        try await interp.eval("""
            print("a")
            await sleep(seconds: 0.15)
            print("b")
            """)
        let elapsed = Date().timeIntervalSince(start)
        // Real suspension: at least 100ms must have passed.
        #expect(elapsed >= 0.1)
        #expect(captured == "a\nb\n")
    }

    @Test func sequentialAwaitsAccumulateDelay() async throws {
        let interp = Interpreter()
        let start = Date()
        try await interp.eval("""
            await sleep(seconds: 0.05)
            await sleep(seconds: 0.05)
            await sleep(seconds: 0.05)
            """)
        let elapsed = Date().timeIntervalSince(start)
        // Three 50ms sleeps in series → ≥ 150ms.
        #expect(elapsed >= 0.13)
    }

    @Test func awaitCanBeUsedInAFunctionBody() async throws {
        let interp = Interpreter()
        var captured = ""
        interp.output = { captured += $0 + "\n" }
        try await interp.eval("""
            func work() async {
                print("start")
                await sleep(seconds: 0.05)
                print("end")
            }
            await work()
            """)
        #expect(captured == "start\nend\n")
    }
}
