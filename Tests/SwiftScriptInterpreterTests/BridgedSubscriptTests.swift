import Testing
import Foundation
@testable import SwiftScriptInterpreter

/// Issue #9: bridged (opaque-carried) types can expose subscripts
/// through the `.subscriptGet` / `.subscriptSet` bridge kinds —
/// `data[0]`, `data[0..<4]`, and the XCUITest-shaped
/// `app.buttons["Sign In"].tap()` chain.
@Suite("Bridged subscripts")
struct BridgedSubscriptTests {

    // MARK: - Data

    @Test func dataByteRead() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            let d = Data([10, 20, 30])
            d[1]
            """#)
        #expect(r == .int(20))
    }

    @Test func dataRangeSliceKeepsAbsoluteIndices() async throws {
        // Stock `Data` range subscripts keep the parent's indices, so
        // `d[1..<4]` is indexed by 1..<4, not rebased to 0.
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            let d = Data([1, 2, 3, 4, 5])
            let slice = d[1..<4]
            (slice.count, slice[1], slice[3])
            """#)
        #expect(r == .tuple([.int(3), .int(2), .int(4)]))
    }

    @Test func dataSliceOutOfSliceBoundsThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                Data([1, 2, 3, 4, 5])[1..<4][0]
                """#)
        }
    }

    @Test func dataClosedRangeSlice() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            Data([9, 8, 7, 6])[1...2].count
            """#)
        #expect(r == .int(2))
    }

    @Test func dataByteWrite() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            import Foundation
            var d = Data([1, 2, 3])
            d[1] = 99
            (d[1], d.count)
            """#)
        #expect(r == .tuple([.int(99), .int(3)]))
    }

    @Test func dataIndexOutOfBoundsThrows() async throws {
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                Data([1])[5]
                """#)
        }
    }

    @Test func dataWriteToLetConstantRejected() async throws {
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                let d = Data([1, 2])
                d[0] = 9
                """#)
        }
    }

    // MARK: - XCUITest-shaped custom module

    /// Mimics an external UI-automation module (issue #9's driving use
    /// case): an app object whose element queries are subscript-first,
    /// with actions recorded so the test can observe the calls.
    private final class TapRecorder: @unchecked Sendable {
        var taps: [String] = []
    }

    private struct FakeXCUIModule: BuiltinModule {
        let name = "FakeXCUI"
        let recorder: TapRecorder

        func register(into i: Interpreter) {
            i.bridges["init TestApp()"] = .`init` { _ in
                .opaque(typeName: "TestApp", value: "app")
            }
            i.bridges["var TestApp.buttons"] = .computed { _ in
                .opaque(typeName: "TestQuery", value: "buttons")
            }
            let recorder = self.recorder
            i.bridges[i.bridgeKey(forSubscriptGetOn: "TestQuery")] = .subscriptGet { receiver, args in
                guard case .opaque(_, let kind as String) = receiver else {
                    throw RuntimeError.invalid("TestQuery subscript: bad receiver")
                }
                // String-keyed (`buttons["Sign In"]`) and
                // `element(boundBy:)`-shaped multi-arg access both land
                // here — bridged subscripts are variadic.
                let key = args.map { arg -> String in
                    switch arg {
                    case .string(let s): return s
                    case .int(let n): return "#\(n)"
                    default: return "?"
                    }
                }.joined(separator: ",")
                return .opaque(typeName: "TestElement", value: "\(kind)[\(key)]")
            }
            i.bridges["func TestElement.tap()"] = .method { receiver, _ in
                guard case .opaque(_, let id as String) = receiver else {
                    throw RuntimeError.invalid("TestElement.tap: bad receiver")
                }
                recorder.taps.append(id)
                return .void
            }
            i.bridges["var TestElement.identifier"] = .computed { receiver in
                guard case .opaque(_, let id as String) = receiver else {
                    throw RuntimeError.invalid("TestElement.identifier: bad receiver")
                }
                return .string(id)
            }
        }
    }

    @Test func xcuiShapedSubscriptChain() async throws {
        let recorder = TapRecorder()
        let interp = Interpreter()
        interp.registerOnImport("FakeXCUI", module: FakeXCUIModule(recorder: recorder))
        _ = try await interp.eval(#"""
            import FakeXCUI
            let app = TestApp()
            app.buttons["Sign In"].tap()
            let el = app.buttons[3]
            el.tap()
            """#)
        #expect(recorder.taps == ["buttons[Sign In]", "buttons[#3]"])
    }

    @Test func bridgedSubscriptVariadicArgs() async throws {
        let recorder = TapRecorder()
        let interp = Interpreter()
        interp.registerOnImport("FakeXCUI", module: FakeXCUIModule(recorder: recorder))
        let r = try await interp.eval(#"""
            import FakeXCUI
            TestApp().buttons["a", 2].identifier
            """#)
        #expect(r == .string("buttons[a,#2]"))
    }

    @Test func unbridgedOpaqueSubscriptFailsLoudly() async throws {
        let interp = Interpreter()
        await #expect(throws: (any Error).self) {
            _ = try await interp.eval(#"""
                import Foundation
                UUID()[0]
                """#)
        }
    }

    // MARK: - Chain-walker parity (shared dispatch)

    @Test func dictSubscriptInsideOptionalChain() async throws {
        let interp = Interpreter()
        let r = try await interp.eval(#"""
            let d: [String: Int]? = ["a": 1]
            d?["a"]
            """#)
        #expect(r == .optional(.int(1)))
    }
}
