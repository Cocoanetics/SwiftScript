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
    }
}
#endif
