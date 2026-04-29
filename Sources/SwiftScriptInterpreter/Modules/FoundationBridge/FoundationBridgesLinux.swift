// Linux aggregator — references the subset of FoundationBridges that
// compiles on swift-corelibs-foundation. Apple-only bridges live in
// `FoundationBridges.swift` (gated whole-file).
#if !canImport(Darwin)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum FoundationBridges {
    nonisolated(unsafe) static let all: [String: Bridge] = {
        let dicts: [[String: Bridge]] = [
            FoundationBridges.calendar,
            FoundationBridges.characterSet,
            FoundationBridges.cocoaError,
            FoundationBridges.cocoaErrorCode,
            FoundationBridges.codingUserInfoKey,
            FoundationBridges.data,
            FoundationBridges.date,
            FoundationBridges.dateComponents,
            FoundationBridges.dateInterval,
            FoundationBridges.decimal,
            FoundationBridges.duration,
            FoundationBridges.fileAttributeKey,
            FoundationBridges.fileAttributeType,
            FoundationBridges.fileManager,
            FoundationBridges.hTTPURLResponse,
            FoundationBridges.indexPath,
            FoundationBridges.indexSet,
            FoundationBridges.indexSetIndex,
            FoundationBridges.indexSetRangeView,
            FoundationBridges.jSONDecoder,
            FoundationBridges.jSONEncoder,
            FoundationBridges.locale,
            FoundationBridges.localeCollation,
            FoundationBridges.localeComponents,
            FoundationBridges.localeCurrency,
            FoundationBridges.localeLanguage,
            FoundationBridges.localeLanguageCode,
            FoundationBridges.localeMeasurementSystem,
            FoundationBridges.localeNumberingSystem,
            FoundationBridges.localeRegion,
            FoundationBridges.localeScript,
            FoundationBridges.localeSubdivision,
            FoundationBridges.localeVariant,
            FoundationBridges.nSBinarySearchingOptions,
            FoundationBridges.nSComparisonPredicateOptions,
            FoundationBridges.nSDataBase64DecodingOptions,
            FoundationBridges.nSDataBase64EncodingOptions,
            FoundationBridges.nSDataReadingOptions,
            FoundationBridges.nSDataSearchOptions,
            FoundationBridges.nSDataWritingOptions,
            FoundationBridges.nSEnumerationOptions,
            FoundationBridges.nSLocaleKey,
            FoundationBridges.nSRegularExpressionMatchingFlags,
            FoundationBridges.nSRegularExpressionMatchingOptions,
            FoundationBridges.nSRegularExpressionOptions,
            FoundationBridges.nSSortOptions,
            FoundationBridges.nSStringCompareOptions,
            FoundationBridges.nSStringEncodingConversionOptions,
            FoundationBridges.notification,
            FoundationBridges.notificationQueueNotificationCoalescing,
            FoundationBridges.objectIdentifier,
            FoundationBridges.opaquePointer,
            FoundationBridges.pOSIXError,
            FoundationBridges.personNameComponents,
            FoundationBridges.processInfo,
            FoundationBridges.propertyListDecoder,
            FoundationBridges.propertyListEncoder,
            FoundationBridges.propertyListSerializationMutabilityOptions,
            FoundationBridges.stringEncoding,
            FoundationBridges.taskPriority,
            FoundationBridges.timeZone,
            FoundationBridges.uRL,
            FoundationBridges.uRLComponents,
            FoundationBridges.uRLError,
            FoundationBridges.uRLErrorCode,
            FoundationBridges.uRLFileResourceType,
            FoundationBridges.uRLQueryItem,
            FoundationBridges.uRLRequest,
            FoundationBridges.uRLResponse,
            FoundationBridges.uRLSession,
            FoundationBridges.uUID,
            FoundationBridges.unsafeMutableRawPointer,
            FoundationBridges.unsafeRawPointer,
        ]
        return dicts.reduce(into: [:]) { acc, dict in
            for (k, v) in dict { acc[k] = v }
        }
    }()
}

extension FoundationModule {
    /// Linux-side `registerGenerated` — installs the aggregated
    /// bridges. Apple-side equivalent in `FoundationBridges.swift`
    /// also installs comparators for dozens of opaque types; we
    /// skip those on Linux since most reference Apple-only types.
    func registerGenerated(into i: Interpreter) {
        for (k, v) in FoundationBridges.all { i.bridges[k] = v }
        registerLinuxGenericBridges(into: i)
    }

    /// Generic-decode bridges that the Apple aggregator inlines into
    /// `registerGenerated`. They can't live in the auto-generated
    /// per-type files because they capture the interpreter via
    /// `[weak i]` and need access to `ScriptCodable`.
    private func registerLinuxGenericBridges(into i: Interpreter) {
        i.bridges["func JSONDecoder.decode<T: Decodable>(_: T.Type, from: Data) throws -> T"] = .method { [weak i] receiver, args in
            guard let interp = i else {
                throw RuntimeError.invalid("JSONDecoder.decode: interpreter unavailable")
            }
            guard args.count == 2 else {
                throw RuntimeError.invalid("JSONDecoder.decode: expected 2 argument(s), got \(args.count)")
            }
            let recv: JSONDecoder = try unboxOpaque(receiver, as: JSONDecoder.self, typeName: "JSONDecoder")
            guard case .opaque(typeName: "Metatype", let typeAny) = args[0],
                  let typeName = typeAny as? String
            else {
                throw RuntimeError.invalid("JSONDecoder.decode: first argument must be a type (`T.self`)")
            }
            let data: Data = try unboxOpaque(args[1], as: Data.self, typeName: "Data")
            do {
                recv.userInfo[.scriptInterpreter] = interp
                recv.userInfo[.scriptTargetType] = typeName
                return try recv.decode(ScriptCodable.self, from: data).value
            } catch {
                throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
            }
        }

        i.bridges["func PropertyListDecoder.decode<T: Decodable>(_: T.Type, from: Data) throws -> T"] = .method { [weak i] receiver, args in
            guard let interp = i else {
                throw RuntimeError.invalid("PropertyListDecoder.decode: interpreter unavailable")
            }
            guard args.count == 2 else {
                throw RuntimeError.invalid("PropertyListDecoder.decode: expected 2 argument(s), got \(args.count)")
            }
            let recv: PropertyListDecoder = try unboxOpaque(receiver, as: PropertyListDecoder.self, typeName: "PropertyListDecoder")
            guard case .opaque(typeName: "Metatype", let typeAny) = args[0],
                  let typeName = typeAny as? String
            else {
                throw RuntimeError.invalid("PropertyListDecoder.decode: first argument must be a type (`T.self`)")
            }
            let data: Data = try unboxOpaque(args[1], as: Data.self, typeName: "Data")
            do {
                recv.userInfo[.scriptInterpreter] = interp
                recv.userInfo[.scriptTargetType] = typeName
                return try recv.decode(ScriptCodable.self, from: data).value
            } catch {
                throw UserThrowSignal(value: .opaque(typeName: "Error", value: error))
            }
        }
    }
}
#endif
