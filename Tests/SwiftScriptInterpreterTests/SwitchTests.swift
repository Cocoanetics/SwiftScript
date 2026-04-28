import Testing
@testable import SwiftScriptInterpreter

@Suite("Switch")
struct SwitchTests {
    @Test func switchOnInt() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func describe(_ n: Int) -> String {
                switch n {
                case 0:
                    return "zero"
                case 1:
                    return "one"
                case 2:
                    return "two"
                default:
                    return "many"
                }
            }
            describe(2)
            """)
        #expect(r == .string("two"))
    }

    @Test func switchDefault() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func describe(_ n: Int) -> String {
                switch n {
                case 0: return "zero"
                default: return "nonzero"
                }
            }
            describe(42)
            """)
        #expect(r == .string("nonzero"))
    }

    @Test func switchMultipleItemsPerCase() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func cls(_ n: Int) -> String {
                switch n {
                case 1, 2, 3: return "small"
                case 4, 5, 6: return "medium"
                default:      return "other"
                }
            }
            cls(5)
            """)
        #expect(r == .string("medium"))
    }

    @Test func switchValueBinding() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func describe(_ n: Int) -> String {
                switch n {
                case 0: return "zero"
                case let x where x < 0: return "negative"
                case let x: return "positive"
                }
            }
            describe(-5)
            """)
        #expect(r == .string("negative"))
    }

    @Test func switchOnRangePattern() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            func bucket(_ n: Int) -> String {
                switch n {
                case 0..<10:    return "single digit"
                case 10..<100:  return "two digit"
                case 100...999: return "three digit"
                default:        return "other"
                }
            }
            bucket(42)
            """)
        #expect(r == .string("two digit"))
    }

    @Test func switchAsExpression() async throws {
        let interp = Interpreter()
        let r = try await interp.eval("""
            let n = 7
            let s = switch n {
                case 0: "zero"
                case 1: "one"
                default: "many"
            }
            s
            """)
        #expect(r == .string("many"))
    }

    @Test func switchOnString() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            func ext(_ s: String) -> String {
                switch s {
                case "txt": return "text"
                case "md":  return "markdown"
                default:    return "unknown"
                }
            }
            ext("md")
            """#)
        #expect(r == .string("markdown"))
    }
}
