// Apple-only entries for the auto-generated String bridge dict.
// `String.propertyList()` lives on NSString and isn't ported to
// swift-corelibs-foundation; `String(localized:)` takes
// `LocalizedStringResource`, also Apple-only. Kept in a separate file
// (rather than `#if`-gated inline in the dict literal, which Swift
// doesn't accept) so `StdlibBridges+String.swift` can stay literal.
#if canImport(Darwin)
import Foundation

extension StdlibBridges {
    nonisolated(unsafe) static let stringApple: [String: Bridge] = [
        "func String.propertyList()": .method { receiver, args in
            guard args.count == 0 else {
                throw RuntimeError.invalid("String.propertyList: expected 0 argument(s), got \(args.count)")
            }
            let recv: String = try unboxString(receiver)
            _ = recv.propertyList()
            return .void
        },
        "init String(localized:)": .`init` { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("init String(localized:): expected 1 argument(s), got \(args.count)")
            }
            return .string(String(localized: try unboxOpaque(args[0], as: LocalizedStringResource.self, typeName: "LocalizedStringResource")))
        },
    ]
}
#endif
