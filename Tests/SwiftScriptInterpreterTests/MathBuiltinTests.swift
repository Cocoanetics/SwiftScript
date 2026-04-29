import Testing
@testable import SwiftScriptInterpreter

@Suite("Math builtins")
struct MathBuiltinTests {
    @Test func sqrtDouble() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("import Foundation\nsqrt(2.0)")
        guard case .double(let v) = r else {
            Issue.record("expected double, got \(r)"); return
        }
        #expect(abs(v - 1.4142135623730951) < 1e-12)
    }

    @Test func sqrtIntPromotes() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("import Foundation\nsqrt(16)")
        #expect(r == .double(4.0))
    }

    @Test func powTwoToTen() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("import Foundation\npow(2.0, 10.0)")
        #expect(r == .double(1024.0))
    }

    @Test func piConstant() async throws {
        // `Double.pi` rides on the auto-generated stdlib bridge, which
        // is gated to canImport(Darwin) — see StdlibBridge.
        let interp = Interpreter()
        let r = try await interp.eval("Double.pi")
        guard case .double(let v) = r else {
            Issue.record("expected double, got \(r)"); return
        }
        #expect(abs(v - .pi) < 1e-15)
    }

    @Test func pythagoras() async throws {
        // sqrt(3*3 + 4*4) == 5
        let interp = Interpreter()
        let r = try await interp.eval("import Foundation\nsqrt(3.0 * 3.0 + 4.0 * 4.0)")
        #expect(r == .double(5.0))
    }

    @Test func nestedCalls() async throws {
        // floor(sqrt(50)) == 7
        let interp = Interpreter()
        let r = try await interp.eval("import Foundation\nfloor(sqrt(50.0))")
        #expect(r == .double(7.0))
    }

    @Test func minMaxInts() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("min(5, 2, 9, 1, 7)") == .int(1))
        #expect(try await interp.eval("max(5, 2, 9, 1, 7)") == .int(9))
    }

    @Test func minMixedNumeric() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("min(3, 0.5, 4)")
        #expect(r == .double(0.5))
    }

    @Test func absInt() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("abs(-7)") == .int(7))
    }

    @Test func absDouble() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("abs(-1.5)") == .double(1.5))
    }
}
