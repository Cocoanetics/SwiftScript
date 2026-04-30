import Testing
@testable import SwiftScriptInterpreter

/// Prefix every script with `import MathExtras` — the module is
/// load-on-import, mirroring the contract a stock-`swift` script sees.
private func mx(_ src: String) -> String { "import MathExtras\n" + src }

@Suite("MathExtras module")
struct MathExtrasTests {
    // MARK: - Foundation-equivalent globals

    @Test func hypotMatchesFoundation() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("import Foundation\nhypot(3.0, 4.0)") == .double(5.0))
    }

    @Test func copysign() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("import Foundation\ncopysign(5.0, -1.0)") == .double(-5.0))
        #expect(try await interp.eval("import Foundation\ncopysign(-5.0, 1.0)") == .double(5.0))
    }

    @Test func fmod() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("import Foundation\nfmod(10.0, 3.0)") == .double(1.0))
    }

    // MARK: - Number theory

    @Test func gcd() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("gcd(48, 18)")) == .int(6))
        #expect(try await interp.eval(mx("gcd(0, 5)")) == .int(5))
        #expect(try await interp.eval(mx("gcd(-12, 8)")) == .int(4))
    }

    @Test func lcm() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("lcm(4, 6)")) == .int(12))
        #expect(try await interp.eval(mx("lcm(0, 5)")) == .int(0))
    }

    @Test func factorial() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("factorial(0)")) == .int(1))
        #expect(try await interp.eval(mx("factorial(6)")) == .int(720))
    }

    @Test func binomial() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("binomial(10, 3)")) == .int(120))
        #expect(try await interp.eval(mx("binomial(5, 0)")) == .int(1))
        #expect(try await interp.eval(mx("binomial(5, 5)")) == .int(1))
    }

    // MARK: - Int / Double instance methods

    @Test func intSignum() async throws {
        let interp = Interpreter()
        // signum() is in stdlib — no MathExtras import needed.
        let r = try await interp.eval("((-7).signum(), 0.signum(), 99.signum())")
        #expect(r == .tuple([.int(-1), .int(0), .int(1)]))
    }

    @Test func intClamped() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(mx("""
            (
                (-5).clamped(to: 0...10),
                7.clamped(to: 0...10),
                15.clamped(to: 0...10)
            )
            """))
        #expect(r == .tuple([.int(0), .int(7), .int(10)]))
    }

    @Test func doubleClamped() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(mx("3.5.clamped(to: 0...3)"))
        #expect(r == .double(3.0))
    }

    @Test func doubleSign() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(mx("((-3.5).sign, 0.0.sign, 3.5.sign)"))
        #expect(r == .tuple([.double(-1.0), .double(0.0), .double(1.0)]))
    }

    @Test func truncatingRemainder() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(mx("10.5.truncatingRemainder(dividingBy: 3.0)"))
        if case .double(let v) = r {
            #expect(abs(v - 1.5) < 1e-12)
        } else {
            Issue.record("expected double, got \(r)")
        }
    }

    // MARK: - Array reductions

    @Test func arraySumInt() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[1, 2, 3, 4].sum()")) == .int(10))
    }

    @Test func arraySumDouble() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[1.5, 2.5, 3.0].sum()")) == .double(7.0))
    }

    @Test func arrayProduct() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[1, 2, 3, 4].product()")) == .int(24))
    }

    @Test func arrayAverage() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[2.0, 4.0, 6.0].average()")) == .double(4.0))
    }

    // MARK: - Bitwise (separate from the module but in the same theme)

    @Test func bitwiseShift() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("5 << 2") == .int(20))
        #expect(try await interp.eval("40 >> 3") == .int(5))
    }

    @Test func bitwiseAndOrXorNot() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval("0b1100 & 0b1010") == .int(0b1000))
        #expect(try await interp.eval("0b1100 | 0b1010") == .int(0b1110))
        #expect(try await interp.eval("0b1100 ^ 0b1010") == .int(0b0110))
        #expect(try await interp.eval("~5") == .int(-6))
    }
}

@Suite("Statistics module")
struct StatisticsTests {
    @Test func median() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0].median()")) == .double(3.5))
        #expect(try await interp.eval(mx("[1.0, 2.0, 3.0].median()")) == .double(2.0))
    }

    @Test func variance() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0].variance()")) == .double(4.0))
    }

    @Test func stdDev() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0].stdDev()")) == .double(2.0))
    }

    @Test func percentile() async throws {
        let interp = Interpreter()
        #expect(try await interp.eval(mx("[1.0, 2.0, 3.0, 4.0].percentile(0.5)")) == .double(2.5))
        #expect(try await interp.eval(mx("[1.0, 2.0, 3.0, 4.0].percentile(0.0)")) == .double(1.0))
        #expect(try await interp.eval(mx("[1.0, 2.0, 3.0, 4.0].percentile(1.0)")) == .double(4.0))
    }

    @Test func mixedIntArrayWorks() async throws {
        // Statistics methods should accept any numeric receiver, not just
        // [Double] — Int elements get promoted.
        let interp = Interpreter()
        let r = try await interp.eval(mx("[1, 2, 3, 4, 5].median()"))
        #expect(r == .double(3.0))
    }
}
