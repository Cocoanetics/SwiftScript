import Testing
@testable import SwiftScriptInterpreter

@Suite("Enums")
struct EnumTests {
    @Test func simpleCase() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Color { case red, green, blue }
            Color.red
            """)
        guard case .enumValue(let t, let c, let p) = r else { Issue.record("not enum"); return }
        #expect(t == "Color" && c == "red" && p.isEmpty)
    }

    @Test func descriptionPlain() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Color { case red, green }
            Color.green
            """)
        #expect(r.description == "green")
    }

    @Test func dotShorthandInLet() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Color { case red, green, blue }
            let c: Color = .green
            c
            """)
        guard case .enumValue(_, let c, _) = r else { Issue.record("not enum"); return }
        #expect(c == "green")
    }

    @Test func switchOnCase() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Color { case red, green, blue }
            func rgb(_ c: Color) -> Int {
                switch c {
                case .red:   return 0xff0000
                case .green: return 0x00ff00
                case .blue:  return 0x0000ff
                }
            }
            rgb(.green)
            """)
        #expect(r == .int(0x00ff00))
    }

    @Test func equality() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Color { case red, green }
            (Color.red == Color.red, Color.red == Color.green)
            """)
        #expect(r == .tuple([.bool(true), .bool(false)]))
    }

    @Test func associatedValuesConstruction() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum R { case ok(Int); case err(String) }
            R.ok(42)
            """)
        guard case .enumValue(let t, let c, let p) = r else { Issue.record("not enum"); return }
        #expect(t == "R" && c == "ok" && p == [.int(42)])
    }

    @Test func associatedValuesPatternBind() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum R { case ok(Int); case err(String) }
            func describe(_ r: R) -> String {
                switch r {
                case .ok(let n):  return "ok:\\(n)"
                case .err(let m): return "err:\\(m)"
                }
            }
            (describe(.ok(7)), describe(.err("boom")))
            """)
        #expect(r == .tuple([.string("ok:7"), .string("err:boom")]))
    }

    @Test func rawValueString() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum D: String { case north = "N"; case south = "S" }
            (D.north.rawValue, D.south.rawValue)
            """#)
        #expect(r == .tuple([.string("N"), .string("S")]))
    }

    @Test func rawValueIntAuto() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Code: Int { case a, b, c }
            (Code.a.rawValue, Code.b.rawValue, Code.c.rawValue)
            """)
        #expect(r == .tuple([.int(0), .int(1), .int(2)]))
    }

    @Test func initFromRawValueSome() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum D: String { case n = "N"; case s = "S" }
            D(rawValue: "N")
            """#)
        guard case .optional(.some(let v)) = r,
              case .enumValue(_, let c, _) = v else {
            Issue.record("expected Optional(.n), got \(r)"); return
        }
        #expect(c == "n")
    }

    @Test func initFromRawValueNone() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            enum D: String { case n = "N" }
            D(rawValue: "X")
            """#)
        #expect(r == .optional(nil))
    }

    @Test func enumMethod() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            enum Sign {
                case positive, negative, zero
                func flip() -> Sign {
                    switch self {
                    case .positive: return .negative
                    case .negative: return .positive
                    case .zero:     return .zero
                    }
                }
            }
            Sign.positive.flip()
            """)
        guard case .enumValue(_, let c, _) = r else { Issue.record("not enum"); return }
        #expect(c == "negative")
    }
}
