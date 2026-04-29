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
        // Apple ships `URLSession.bytes(from:)` natively; on Linux we
        // pump chunks through a delegate-driven `AsyncThrowingStream<Data>`
        // (see `URLSessionLinuxStreaming.swift`) and walk each chunk's
        // bytes between yields. Both branches are real streams — no
        // platform buffers the full payload before the script sees the
        // first byte — so memory stays flat regardless of payload size.
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
                // The receiver session is ignored on Linux: swift-corelibs
                // URLSession can't have a delegate attached after the fact,
                // so the streaming helper spins up a one-shot session per
                // call. Same cost shape as `data(from:)` would have had.
                _ = session
                let (chunks, response) = try await linuxStreamingDataChunks(url: url)
                var chunkIterator = chunks.makeAsyncIterator()
                var currentChunk: Data?
                var currentIndex = 0
                let stream = AsyncStreamBox {
                    while true {
                        if let chunk = currentChunk, currentIndex < chunk.endIndex {
                            let byte = chunk[currentIndex]
                            currentIndex = chunk.index(after: currentIndex)
                            return .int(Int(byte))
                        }
                        guard let nextChunk = try await chunkIterator.next() else {
                            return nil
                        }
                        currentChunk = nextChunk
                        currentIndex = nextChunk.startIndex
                    }
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
