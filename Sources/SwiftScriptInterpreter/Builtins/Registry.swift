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
    }

    func registerBuiltin(name: String, body: @escaping ([Value]) async throws -> Value) {
        let fn = Function(name: name, parameters: [], kind: .builtin(body))
        rootScope.bind(name, value: .function(fn), mutable: false)
    }
}
