#if !canImport(Darwin)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Delegate-based streaming adapter for swift-corelibs-foundation, which
/// doesn't ship `URLSession.bytes(from:)`. We drive a one-shot
/// `URLSession` whose delegate forwards `didReceive(data:)` chunks into
/// an `AsyncThrowingStream<Data>`, and surfaces the response via a
/// continuation that resumes the moment headers arrive — before the body
/// has finished. The script-side `for await b in stream { ... }` loop
/// then progresses with the network instead of waiting for the full
/// payload.
///
/// Lifetime: the chunk stream's `onTermination` keeps `task` and
/// `session` alive while bytes are being consumed, then calls
/// `finishTasksAndInvalidate()` to break URLSession's intentional
/// session↔delegate retain cycle.
final class StreamingURLDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseCont: CheckedContinuation<URLResponse, Error>?
    private let chunkCont: AsyncThrowingStream<Data, Error>.Continuation

    init(
        chunkCont: AsyncThrowingStream<Data, Error>.Continuation,
        responseCont: CheckedContinuation<URLResponse, Error>
    ) {
        self.chunkCont = chunkCont
        self.responseCont = responseCont
    }

    /// Pop the response continuation atomically so headers-arrived and
    /// task-completed-with-error don't both try to resume it.
    private func takeResponseCont() -> CheckedContinuation<URLResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = responseCont
        responseCont = nil
        return c
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        takeResponseCont()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        chunkCont.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            // Surface the error to whichever side is still waiting.
            takeResponseCont()?.resume(throwing: error)
            chunkCont.finish(throwing: error)
        } else {
            // Finishing without ever having delivered headers means the
            // task ended before `didReceive(response:)` fired; surface
            // that as an error so the caller doesn't hang.
            takeResponseCont()?.resume(throwing: URLError(.badServerResponse))
            chunkCont.finish()
        }
    }
}

/// Kicks off `url`'s data task and returns the response (resolved as
/// soon as headers arrive) plus a stream of body chunks. The session
/// is owned by the stream's `onTermination` so it lives exactly as
/// long as the consumer is reading bytes.
func linuxStreamingDataChunks(
    url: URL
) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
    let (chunkStream, chunkCont) = AsyncThrowingStream<Data, Error>.makeStream()

    let response = try await withCheckedThrowingContinuation {
        (respCont: CheckedContinuation<URLResponse, Error>) in
        let delegate = StreamingURLDataDelegate(
            chunkCont: chunkCont,
            responseCont: respCont
        )
        // `URLSession.shared` has a nil delegate and we can't attach
        // one after the fact, so we always use a one-shot session for
        // streaming. `task` and `session` are captured by the
        // termination handler below and live as long as the stream.
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: url)
        chunkCont.onTermination = { @Sendable _ in
            task.cancel()
            session.finishTasksAndInvalidate()
        }
        task.resume()
    }

    return (chunkStream, response)
}
#endif
