extension Interpreter {
    func registerBuiltins() {
        // Stdlib-shaped builtins — always available, no import required.
        registerMathBuiltins()
        registerIOBuiltins()
        // Auto-generated bridges harvested from the Swift stdlib symbol
        // graph (`Int.max`, `Double.pi`, `Int.advanced(by:)`, …). The
        // dict aggregator and per-comparator gating in
        // `StdlibBridges.swift` keep the Apple-only entries
        // (`String.propertyList`, `LocalizedStringResource`,
        // `OperationQueue.SchedulerTimeType`, …) out of the Linux build.
        registerGeneratedStdlib(into: self)
        registerStringCodeUnitViews()

        // `MathExtras` extras (gcd, factorial, .clamped, .median, …) ship
        // as a real Swift library target as well, so the same source
        // works under stock `swift` (with the prebuilt module + dylib on
        // the search path). Both the interpreter's bridges and the
        // statistics helpers live behind `import MathExtras`.
        let mathExtras = MathExtrasModule()
        registerOnImport("MathExtras", module: mathExtras)
        let statistics = StatisticsModule()
        registerOnImport("MathExtras", module: statistics)
        // Stdlib `Set` and `Dictionary` constructors — always available.
        register(module: SetModule())
        register(module: DictionaryModule())
        // Concurrency shims — `Task { … }`, `withTaskGroup(...)`,
        // `actor` declarations all run synchronously since this
        // interpreter has no scheduler.
        register(module: ConcurrencyModule())
        // `Mirror(reflecting:)` — structural reflection over `Value`
        // for generic dump / debug helpers. Always-on (no import).
        register(module: MirrorModule())

        // Foundation-side: registered lazily on `import Foundation` (and
        // on `import Darwin`/`Glibc`, which bring the same C-math
        // globals). Without the import, sqrt/hypot/etc. are unbound and
        // users get the same `cannot find 'X' in scope` error swiftc
        // produces — rendered with caret pointers via the runtime-error
        // formatter.
        let foundationModule = FoundationModule()
        registerOnImport("Foundation", module: foundationModule)
        registerOnImport("Darwin",     module: foundationModule)
        registerOnImport("Glibc",      module: foundationModule)
        registerOnImport("ucrt",       module: foundationModule)
        registerOnImport("WinSDK",     module: foundationModule)
        // Calendar/DateComponents — also Foundation-gated. Hand-rolled
        // because the symbol-graph surface uses `Set<Calendar.Component>`,
        // a generic over an enum that the bridge generator can't model.
        let calendarModule = CalendarModule()
        registerOnImport("Foundation", module: calendarModule)
        registerOnImport("Darwin",     module: calendarModule)
        registerOnImport("Glibc",      module: calendarModule)
        registerOnImport("ucrt",       module: calendarModule)
        registerOnImport("WinSDK",     module: calendarModule)
        // JSONEncoder/JSONDecoder + String(data:encoding:) — walk the
        // `Value` tree directly rather than rely on Codable conformance,
        // which the interpreter doesn't model.
        let jsonModule = JSONModule()
        registerOnImport("Foundation", module: jsonModule)
        registerOnImport("Darwin",     module: jsonModule)
        registerOnImport("Glibc",      module: jsonModule)
        registerOnImport("ucrt",       module: jsonModule)
        registerOnImport("WinSDK",     module: jsonModule)
        // URLSession.shared.data(from:) — surface enough to fetch and
        // decode JSON over HTTP. Foundation-gated.
        let urlSessionModule = URLSessionModule()
        registerOnImport("Foundation", module: urlSessionModule)
        registerOnImport("Darwin",     module: urlSessionModule)
        registerOnImport("Glibc",      module: urlSessionModule)
        registerOnImport("ucrt",       module: urlSessionModule)
        registerOnImport("WinSDK",     module: urlSessionModule)
        // ProcessInfo identity overrides — bridges that route
        // `userName` / `processIdentifier` / `arguments` /
        // `environment` through `ShellKit.Shell.current`'s
        // `HostInfo` / `Environment` / `scriptName`. The generator
        // already redirects the auto-discovered identity reads
        // (`hostName`, `processName`); this module fills in the
        // ones whose Swift type the generator can't bridge
        // (`Int32`, `[String]`, `[String: String]`).
        let identityModule = IdentityModule()
        registerOnImport("Foundation", module: identityModule)
        registerOnImport("Darwin",     module: identityModule)
        registerOnImport("Glibc",      module: identityModule)
        registerOnImport("ucrt",       module: identityModule)
        registerOnImport("WinSDK",     module: identityModule)
        // `Subprocess.run(...)` — collected-output bridge that mirrors
        // swift-subprocess's API shape and routes every call through
        // `ShellKit.Shell.current.processLauncher.launch(...)`.
        // Standalone gets `DefaultProcessLauncher` (real exec via
        // swift-subprocess); under SwiftBash gets `BashProcessLauncher`
        // (resolves against the bash command registry, no `posix_spawn`).
        registerOnImport("Subprocess", module: SubprocessModule())
    }

    func registerBuiltin(name: String, body: @escaping ([Value]) async throws -> Value) {
        let fn = Function(name: name, parameters: [], kind: .builtin(body))
        rootScope.bind(name, value: .function(fn), mutable: false)
    }

    /// `String.utf8` / `.utf16` / `.unicodeScalars` — modeled as eager
    /// arrays of code units so `.count` reports what stock Swift
    /// reports (`"héllo".utf8.count == 6`, not the Character count)
    /// and `for`-loops iterate units, not Characters. Stdlib surface:
    /// always registered, no import required — matching stock Swift.
    func registerStringCodeUnitViews() {
        bridges["var String.utf8"] = .computed { recv in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.utf8: receiver must be String")
            }
            return .array(s.utf8.map { .int(Int($0)) })
        }
        bridges["var String.utf16"] = .computed { recv in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.utf16: receiver must be String")
            }
            return .array(s.utf16.map { .int(Int($0)) })
        }
        // Scalars stay opaque `Unicode.Scalar`s (not bare Ints) so
        // `String(describing:)` shows the character and property
        // reads beyond `.value` fail loudly instead of silently
        // acting like integers.
        bridges["var String.unicodeScalars"] = .computed { recv in
            guard case .string(let s) = recv else {
                throw RuntimeError.invalid("String.unicodeScalars: receiver must be String")
            }
            return .array(s.unicodeScalars.map {
                .opaque(typeName: "Unicode.Scalar", value: $0)
            })
        }
        bridges["var Unicode.Scalar.value: Int"] = .computed { recv in
            guard case .opaque(_, let any) = recv,
                  let scalar = any as? Unicode.Scalar
            else {
                throw RuntimeError.invalid("Unicode.Scalar.value: receiver must be Unicode.Scalar")
            }
            return .int(Int(scalar.value))
        }
    }
}
