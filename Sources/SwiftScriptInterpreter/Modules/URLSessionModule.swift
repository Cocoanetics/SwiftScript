import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession bridge — what's left after auto-generation drains the
/// rest. The symbol-graph generator now emits:
///
///   - `URLSession.shared` static
///   - `URLSession.data(from:)` async (and download / upload)
///   - `URLResponse.url`, `.mimeType`, `.textEncodingName`, `.suggestedFilename`
///   - `HTTPURLResponse.statusCode` and other HTTP fields
///
/// What remains hand-rolled here couldn't be auto-generated:
///   - `URLSession.bytes(from:)` returns the typed `URLSession.AsyncBytes`
///     which we don't model — we erase it into our `AsyncStreamBox`.
///   - `URLResponse.expectedContentLength` is `Int64`; the auto-bridge
///     skips because we don't bridge non-Int integer types.
///   - `URLResponse.statusCode` re-cases to `HTTPURLResponse` so script
///     code that holds a `URLResponse`-typed opaque still gets the
///     status without explicit downcasting.
struct URLSessionModule: BuiltinModule {
    let name = "URLSession"

    func register(into i: Interpreter) {
        // `bytes(from:) async throws -> (AsyncBytes, URLResponse)` —
        // returns a tuple of an AsyncStream of bytes (each a `.int`
        // 0..<256) and the response. Lets script code do
        // `for await b in stream { … }` over real async byte data.
        //
        // On Apple platforms we use the native `URLSession.bytes(from:)`
        // and forward each byte. swift-corelibs-foundation doesn't ship
        // that method, so on Linux we fetch the full payload via
        // `data(from:)` and re-emit it byte-by-byte — same script-side
        // API, no real streaming benefit, but scripts behave identically.
        i.bridges["func URLSession.bytes()"] = .method { recv, args in
            guard case .opaque(_, let any) = recv,
                  let session = any as? URLSession
            else {
                throw RuntimeError.invalid("URLSession.bytes: bad receiver")
            }
            guard args.count == 1,
                  case .opaque(typeName: "URL", let urlAny) = args[0],
                  let url = urlAny as? URL
            else {
                throw RuntimeError.invalid("URLSession.bytes(from:): expected a URL argument")
            }
            do {
#if canImport(Darwin)
                let (bytes, response) = try await session.bytes(from: url)
                var iterator = bytes.makeAsyncIterator()
                let stream = AsyncStreamBox {
                    guard let byte = try await iterator.next() else { return nil }
                    return .int(Int(byte))
                }
#else
                let (data, response) = try await session.data(from: url)
                var idx = data.startIndex
                let stream = AsyncStreamBox {
                    guard idx < data.endIndex else { return nil }
                    let byte = data[idx]
                    idx = data.index(after: idx)
                    return .int(Int(byte))
                }
#endif
                return .tuple(
                    [
                        .opaque(typeName: "AsyncStream", value: stream),
                        .opaque(typeName: "URLResponse", value: response),
                    ],
                    labels: []
                )
            } catch {
                throw RuntimeError.invalid("URLSession.bytes(from:): \(error)")
            }
        }

        // `URLResponse.expectedContentLength` is `Int64` — narrow to
        // Int for script consumption.
        i.bridges["var URLResponse.expectedContentLength"] = .computed { recv in
            guard case .opaque(_, let any) = recv,
                  let r = any as? URLResponse
            else { return .int(-1) }
            return .int(Int(r.expectedContentLength))
        }
        // `URLResponse.statusCode` — surfaces `HTTPURLResponse.statusCode`
        // off the parent type so script code holding a URLResponse-typed
        // opaque still reads it. The auto-genned bridge sits on
        // HTTPURLResponse which our type-erasure can't dispatch to from
        // a URLResponse receiver.
        i.bridges["var URLResponse.statusCode"] = .computed { recv in
            guard case .opaque(_, let any) = recv,
                  let http = any as? HTTPURLResponse
            else { return .optional(nil) }
            return .optional(.int(http.statusCode))
        }
    }
}
