import Foundation

/// URLSession bridge — exposes the most common async network surface
/// (`URLSession.shared.data(from:)`) so script code can fetch JSON,
/// decode it through the Codable bridge, and use it. Demonstrates
/// the full async stack: real `await` propagates through the
/// interpreter, lands on `URLSession`'s real async API, and resumes.
struct URLSessionModule: BuiltinModule {
    let name = "URLSession"

    func register(into i: Interpreter) {
        i.registerStaticValue(
            on: "URLSession",
            name: "shared",
            value: .opaque(typeName: "URLSession", value: URLSession.shared)
        )

        // `data(from: URL) async throws -> (Data, URLResponse)` — real
        // suspending call. The interpreter's async `await` lands on
        // Foundation's runtime, then resumes with the decoded tuple.
        i.registerMethod(on: "URLSession", name: "data") { recv, args in
            guard case .opaque(_, let any) = recv,
                  let session = any as? URLSession
            else {
                throw RuntimeError.invalid("URLSession.data: bad receiver")
            }
            guard args.count == 1,
                  case .opaque(typeName: "URL", let urlAny) = args[0],
                  let url = urlAny as? URL
            else {
                throw RuntimeError.invalid("URLSession.data(from:): expected a URL argument")
            }
            do {
                let (data, response) = try await session.data(from: url)
                return .tuple(
                    [
                        .opaque(typeName: "Data", value: data),
                        .opaque(typeName: "URLResponse", value: response),
                    ],
                    labels: []
                )
            } catch {
                throw RuntimeError.invalid("URLSession.data(from:): \(error)")
            }
        }

        // `bytes(from:) async throws -> (AsyncBytes, URLResponse)` —
        // returns a tuple of an AsyncStream of bytes (each a `.int`
        // 0..<256) and the response. Lets script code do
        // `for await b in stream { … }` over real async byte data.
        i.registerMethod(on: "URLSession", name: "bytes") { recv, args in
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
                let (bytes, response) = try await session.bytes(from: url)
                // Erase the typed AsyncIterator into a closure the
                // interpreter can drive.
                var iterator = bytes.makeAsyncIterator()
                let stream = AsyncStreamBox {
                    guard let byte = try await iterator.next() else { return nil }
                    return .int(Int(byte))
                }
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

        // URLResponse computed properties commonly inspected after a
        // request — status code, MIME type, expected length.
        i.registerComputed(on: "URLResponse", name: "expectedContentLength") { recv in
            guard case .opaque(_, let any) = recv,
                  let r = any as? URLResponse
            else { return .int(-1) }
            return .int(Int(r.expectedContentLength))
        }
        i.registerComputed(on: "URLResponse", name: "mimeType") { recv in
            guard case .opaque(_, let any) = recv,
                  let r = any as? URLResponse,
                  let m = r.mimeType
            else { return .optional(nil) }
            return .optional(.string(m))
        }
        // HTTPURLResponse is a subclass — expose its statusCode the same way.
        i.registerComputed(on: "URLResponse", name: "statusCode") { recv in
            guard case .opaque(_, let any) = recv,
                  let http = any as? HTTPURLResponse
            else { return .optional(nil) }
            return .optional(.int(http.statusCode))
        }
    }
}
