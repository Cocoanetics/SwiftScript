// Apple-only String.Index entries. `debugDescription` is on Apple's
// stdlib but not bridged in swift-corelibs equivalents.
#if canImport(Darwin)
import Foundation

extension StdlibBridges {
    nonisolated(unsafe) static let stringIndexApple: [String: Bridge] = [
        "var String.Index.debugDescription: String": .computed { receiver in
            let recv: String.Index = try unboxOpaque(receiver, as: String.Index.self, typeName: "String.Index")
            return .string(recv.debugDescription)
        },
    ]
}
#endif
