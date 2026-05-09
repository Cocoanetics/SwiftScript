import Foundation
import ShellKit

/// `import Subprocess` bridge — a minimal v1 surface that mirrors
/// swift-subprocess's collected-output `run(...)` shape and routes
/// every call through `ShellKit.Shell.current.processLauncher.launch(...)`.
///
/// ```swift
/// import Subprocess
///
/// let r = try await Subprocess.run(
///     .name("echo"),
///     arguments: ["hello"],
///     output: .string(limit: 4096))
///
/// if r.terminationStatus.isSuccess {
///     print(r.standardOutput ?? "")
/// }
/// ```
///
/// Routing:
/// - **Standalone** SwiftScript scripts → `DefaultProcessLauncher` →
///   real `posix_spawn` via swift-subprocess (macOS / Linux / Windows
///   / Android).
/// - **Under SwiftBash** → `BashProcessLauncher` → resolves against
///   the bash command registry (no `posix_spawn`, ever).
/// - **Sandbox-bound** without a virtualised launcher →
///   `ProcessLaunchDenied`, surfaced to the script as a thrown
///   error.
///
/// What v1 ships:
/// - `Executable.name(_:)` / `.path(_:)`
/// - `Output.string(limit:)` / `Output.discarded` and the symmetric
///   `ErrorOutput.string(limit:)` / `ErrorOutput.discarded`
/// - `Subprocess.run(_:arguments:output:)` and
///   `Subprocess.run(_:arguments:output:error:)`
/// - `ExecutionRecord.{terminationStatus, standardOutput,
///   standardError, processIdentifier}`
/// - `TerminationStatus.{isSuccess, exitedCode, signaledCode}`
///
/// What v1 defers (script-author-visible items the bridge could grow
/// later, ordered by likely demand): `environment:` /
/// `workingDirectory:` / `input:` parameters on `run`,
/// closure-form `run(...) { execution, stdout in ... }` overloads,
/// streaming `AsyncSequence<Data>` outputs, `PlatformOptions` (spawn
/// attrs / file actions). For v1, environment + cwd come from
/// `ShellKit.Shell.current` and stdin is empty — this matches the
/// 95%-case shell-out pattern.
struct SubprocessModule: BuiltinModule {
    let name = "Subprocess"

    func register(into i: Interpreter) {
        registerExecutable(into: i)
        registerOutputStrategies(into: i)
        registerRun(into: i)
        registerExecutionRecord(into: i)
        registerTerminationStatus(into: i)
    }

    // MARK: Executable

    private func registerExecutable(into i: Interpreter) {
        // Bridge keys for static methods use empty `()` — the static-
        // member resolver looks up the function value with empty
        // labels, then the caller's positional args flow into the
        // body verbatim. (See `Double.minimum` / `Bool.random` for the
        // existing precedent.)
        i.bridges["static func Executable.name()"] = .staticMethod { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Executable.name(_:): expected 1 argument(s), got \(args.count)")
            }
            return boxOpaque(Executable.name(try unboxString(args[0])), typeName: "Executable")
        }
        i.bridges["static func Executable.path()"] = .staticMethod { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Executable.path(_:): expected 1 argument(s), got \(args.count)")
            }
            return boxOpaque(Executable.path(try unboxString(args[0])), typeName: "Executable")
        }
    }

    // MARK: Output / ErrorOutput strategies

    private func registerOutputStrategies(into i: Interpreter) {
        // Two parallel surfaces — `Output` and `ErrorOutput` — wrap
        // the same `SubprocessIOStrategy` enum but carry distinct
        // type names so the dispatch table can tell them apart at
        // call-site label resolution. Mirrors swift-subprocess's
        // `OutputProtocol` / `ErrorOutputProtocol` split (renamed
        // here because `Error` collides with Swift's built-in
        // `Error` protocol identifier in script syntax).
        i.bridges["static func Output.string()"] = .staticMethod { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("Output.string(limit:): expected 1 argument(s), got \(args.count)")
            }
            return boxOpaque(SubprocessIOStrategy.string(limit: try unboxInt(args[0])), typeName: "Output")
        }
        i.bridges["static let Output.discarded"] = .staticValue(
            boxOpaque(SubprocessIOStrategy.discarded, typeName: "Output"))

        i.bridges["static func ErrorOutput.string()"] = .staticMethod { args in
            guard args.count == 1 else {
                throw RuntimeError.invalid("ErrorOutput.string(limit:): expected 1 argument(s), got \(args.count)")
            }
            return boxOpaque(SubprocessIOStrategy.string(limit: try unboxInt(args[0])), typeName: "ErrorOutput")
        }
        i.bridges["static let ErrorOutput.discarded"] = .staticValue(
            boxOpaque(SubprocessIOStrategy.discarded, typeName: "ErrorOutput"))
    }

    // MARK: Subprocess.run overloads

    private func registerRun(into i: Interpreter) {
        // Single bridge entry — the body dispatches by argument count
        // for the two supported overload shapes:
        //   3 args: (executable, arguments, output)
        //   4 args: (executable, arguments, output, error)
        // Caller-supplied labels (`arguments:` / `output:` / `error:`)
        // are stripped by the static-member resolver before we see
        // them, so positional order is the contract.
        i.bridges["static func Subprocess.run()"] = .staticMethod { args in
            switch args.count {
            case 3:
                return try await runImpl(
                    executable: args[0],
                    arguments: args[1],
                    output: args[2],
                    error: nil)
            case 4:
                return try await runImpl(
                    executable: args[0],
                    arguments: args[1],
                    output: args[2],
                    error: args[3])
            default:
                throw RuntimeError.invalid(
                    "Subprocess.run: expected 3 or 4 arguments, got \(args.count)")
            }
        }
    }

    // MARK: ExecutionRecord

    private func registerExecutionRecord(into i: Interpreter) {
        i.bridges["var ExecutionRecord.terminationStatus"] = .computed { recv in
            let r: ScriptExecutionRecord = try unboxOpaque(
                recv, as: ScriptExecutionRecord.self, typeName: "ExecutionRecord")
            return boxOpaque(r.record.terminationStatus, typeName: "TerminationStatus")
        }
        // `.discarded` → `nil`. `.string(limit:)` → `Optional(String)`
        // even if the captured byte buffer is empty — that's how a
        // script distinguishes a silent command from a discarded
        // stream (matches swift-subprocess's `Optional<String>` with
        // empty-string-on-no-output semantics).
        i.bridges["var ExecutionRecord.standardOutput"] = .computed { recv in
            let r: ScriptExecutionRecord = try unboxOpaque(
                recv, as: ScriptExecutionRecord.self, typeName: "ExecutionRecord")
            guard r.outputCaptured else { return .optional(nil) }
            return .optional(.string(String(decoding: r.record.standardOutput, as: UTF8.self)))
        }
        i.bridges["var ExecutionRecord.standardError"] = .computed { recv in
            let r: ScriptExecutionRecord = try unboxOpaque(
                recv, as: ScriptExecutionRecord.self, typeName: "ExecutionRecord")
            guard r.errorCaptured else { return .optional(nil) }
            return .optional(.string(String(decoding: r.record.standardError, as: UTF8.self)))
        }
        i.bridges["var ExecutionRecord.processIdentifier"] = .computed { recv in
            let r: ScriptExecutionRecord = try unboxOpaque(
                recv, as: ScriptExecutionRecord.self, typeName: "ExecutionRecord")
            return .int(Int(r.record.processIdentifier))
        }
    }

    // MARK: TerminationStatus

    private func registerTerminationStatus(into i: Interpreter) {
        i.bridges["var TerminationStatus.isSuccess"] = .computed { recv in
            let s: TerminationStatus = try unboxOpaque(recv, as: TerminationStatus.self, typeName: "TerminationStatus")
            return .bool(s.isSuccess)
        }
        // Pattern matching against opaque enum values is out of scope
        // for the v1 interpreter, so flatten the two cases into
        // optional accessors. Scripts read `r.terminationStatus.exitedCode`
        // (nil if signaled) and `.signaledCode` (nil if exited)
        // instead of `if case .exited(let c) = r.terminationStatus`.
        i.bridges["var TerminationStatus.exitedCode"] = .computed { recv in
            let s: TerminationStatus = try unboxOpaque(recv, as: TerminationStatus.self, typeName: "TerminationStatus")
            if case .exited(let code) = s { return .optional(.int(Int(code))) }
            return .optional(nil)
        }
        i.bridges["var TerminationStatus.signaledCode"] = .computed { recv in
            let s: TerminationStatus = try unboxOpaque(recv, as: TerminationStatus.self, typeName: "TerminationStatus")
            if case .signaled(let sig) = s { return .optional(.int(Int(sig))) }
            return .optional(nil)
        }
    }
}

// MARK: - Internals

/// IO strategy used by ``Subprocess.run`` to decide how to handle each
/// stream. v1 only models `.string(limit:)` (capture into a UTF-8
/// string up to `limit` bytes) and `.discarded`. Stream-based
/// (`AsyncSequence<Data>`) and file-descriptor strategies that
/// swift-subprocess offers are deferred.
enum SubprocessIOStrategy: Sendable {
    case discarded
    case string(limit: Int)
}

/// Wraps the launcher's `ExecutionRecord` with per-stream "captured"
/// flags so ``ExecutionRecord/standardOutput`` /
/// ``ExecutionRecord/standardError`` can return `Optional("")` for a
/// `.string(limit:)` capture that produced zero bytes — distinct from
/// `nil` for `.discarded` which never captured at all. Without this
/// the script can't tell a silent command apart from a discarded
/// stream (Codex P1 on PR #5).
struct ScriptExecutionRecord: Sendable {
    let record: ExecutionRecord
    let outputCaptured: Bool   // false when `Output.discarded`
    let errorCaptured: Bool    // false when `ErrorOutput.discarded`
}

/// Thrown when a stream produced more bytes than the supplied
/// `Output.string(limit:)` / `ErrorOutput.string(limit:)` budget.
/// Matches swift-subprocess's "throw on overflow" contract — silently
/// truncating would hand scripts incomplete data with no way to
/// detect the loss (Codex P1 on PR #5).
struct SubprocessOutputLimitExceeded: Error, CustomStringConvertible, Sendable {
    /// Which stream overflowed.
    let stream: Stream
    /// The limit that was exceeded.
    let limit: Int

    enum Stream: String, Sendable {
        case standardOutput, standardError
    }

    var description: String {
        "Subprocess.\(stream.rawValue) exceeded the configured limit of \(limit) bytes"
    }
}

/// Shared body for every `Subprocess.run` overload. Resolves the
/// strategies, allocates buffering ``OutputSink``s where the strategy
/// asks for captured bytes, dispatches through
/// `Shell.current.processLauncher.launch(...)`, and folds the buffered
/// bytes into a returned ``ExecutionRecord``.
private func runImpl(
    executable: Value,
    arguments: Value,
    output: Value,
    error: Value?
) async throws -> Value {
    let exe = try unboxOpaque(executable, as: Executable.self, typeName: "Executable")

    // Accept `[String]` (the ergonomic call-site form swift-subprocess
    // gets via `ExpressibleByArrayLiteral` on `Arguments`) or a boxed
    // `Arguments` opaque (in case a future bridge adds the explicit
    // type).
    let args: Arguments
    if case .array(let arr) = arguments {
        let strs = try arr.map { try unboxString($0) }
        args = Arguments(strs)
    } else if case .opaque(let n, let any) = arguments,
              n == "Arguments",
              let a = any as? Arguments {
        args = a
    } else {
        throw RuntimeError.invalid("Subprocess.run: arguments must be [String] (got \(arguments))")
    }

    let outStrategy = try unboxOpaque(output, as: SubprocessIOStrategy.self, typeName: "Output")
    let errStrategy: SubprocessIOStrategy
    if let e = error {
        errStrategy = try unboxOpaque(e, as: SubprocessIOStrategy.self, typeName: "ErrorOutput")
    } else {
        errStrategy = .discarded
    }

    let outBuf = StrategyBuffer(strategy: outStrategy)
    let errBuf = StrategyBuffer(strategy: errStrategy)

    let shell = ShellKit.Shell.current
    let record = try await shell.processLauncher.launch(
        exe,
        arguments: args,
        environment: shell.environment,
        workingDirectory: nil,
        input: .empty,
        output: outBuf.sink,
        error: errBuf.sink)

    // Strategy semantics:
    // - `.discarded` → no captured bytes; script reads `nil` regardless
    //   of what the launcher returned. Honours the script's "don't
    //   capture" contract — `DefaultProcessLauncher` does populate
    //   `record.standardOutput` even when the supplied sink is
    //   discarding, so we drop the launcher copy here too.
    // - `.string(limit:)` → prefer the bridge-supplied buffer (what
    //   actually landed in the user's allocation), fall back to the
    //   launcher's record buffer. `BashProcessLauncher` streams to the
    //   sink only and leaves the record empty; `DefaultProcessLauncher`
    //   populates both. If the buffer overflowed the configured limit,
    //   throw rather than silently truncate (matches swift-subprocess).
    let outBytes: Data
    switch outStrategy {
    case .discarded:
        outBytes = Data()
    case .string(let limit):
        if let captured = outBuf.captured {
            if captured.overflowed {
                throw SubprocessOutputLimitExceeded(stream: .standardOutput, limit: limit)
            }
            outBytes = captured.data
        } else {
            outBytes = record.standardOutput
            if outBytes.count > limit {
                throw SubprocessOutputLimitExceeded(stream: .standardOutput, limit: limit)
            }
        }
    }
    let errBytes: Data
    switch errStrategy {
    case .discarded:
        errBytes = Data()
    case .string(let limit):
        if let captured = errBuf.captured {
            if captured.overflowed {
                throw SubprocessOutputLimitExceeded(stream: .standardError, limit: limit)
            }
            errBytes = captured.data
        } else {
            errBytes = record.standardError
            if errBytes.count > limit {
                throw SubprocessOutputLimitExceeded(stream: .standardError, limit: limit)
            }
        }
    }

    let merged = ExecutionRecord(
        processIdentifier: record.processIdentifier,
        terminationStatus: record.terminationStatus,
        standardOutput: outBytes,
        standardError: errBytes)
    let scriptRecord = ScriptExecutionRecord(
        record: merged,
        outputCaptured: { if case .string = outStrategy { return true } else { return false } }(),
        errorCaptured: { if case .string = errStrategy { return true } else { return false } }())

    return boxOpaque(scriptRecord, typeName: "ExecutionRecord")
}

/// Pair of `OutputSink` + optional capture buffer driven by a
/// ``SubprocessIOStrategy``. `.discarded` returns a no-op sink with
/// no buffer; `.string(limit:)` returns a sink that appends every
/// chunk to a length-bounded byte buffer the run body reads back.
private struct StrategyBuffer {
    let sink: OutputSink
    /// Captured bytes plus an overflow flag if the strategy was
    /// `.string(limit:)`; nil for `.discarded`. The presence-vs-nil
    /// distinction lets the run body tell "no buffer was allocated"
    /// (fall back to the launcher's record) from "buffer was
    /// allocated and produced zero bytes" (script-visible empty
    /// string).
    var captured: (data: Data, overflowed: Bool)? { box?.read() }

    private let box: BufferBox?

    init(strategy: SubprocessIOStrategy) {
        switch strategy {
        case .discarded:
            self.sink = .discard
            self.box = nil
        case .string(let limit):
            let b = BufferBox(limit: limit)
            self.box = b
            // Capturing `b` (a class) by value gives every write the
            // same instance; per-write append is locked.
            self.sink = OutputSink(onWrite: { d in b.append(d) })
        }
    }
}

/// Length-bounded byte buffer that records overflow without
/// throwing — `OutputSink.onWrite` is non-throwing, so the throw
/// has to happen later out of the run body when it inspects the
/// captured state.
private final class BufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private var overflowed = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if buf.count + d.count > limit {
            overflowed = true
        }
        let remaining = limit - buf.count
        guard remaining > 0 else { return }
        if d.count <= remaining {
            buf.append(d)
        } else {
            buf.append(d.prefix(remaining))
        }
    }

    func read() -> (data: Data, overflowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (buf, overflowed)
    }
}
