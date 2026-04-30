// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftScript",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "SwiftScriptAST", targets: ["SwiftScriptAST"]),
        .library(name: "SwiftScriptInterpreter", targets: ["SwiftScriptInterpreter"]),
        // Distributed as a dynamic library so a stock-`swift` script can
        // pick it up via `-I .build/.../debug -L ... -lMathExtras`. The
        // SwiftScript interpreter recognizes `import MathExtras` and
        // registers the equivalent functions in its bridge table, so the
        // same source runs under both runtimes.
        .library(name: "MathExtras", type: .dynamic, targets: ["MathExtras"]),
        .executable(name: "swift-script", targets: ["swift-script"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "SwiftScriptAST",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            ],
            path: "Sources/SwiftScriptAST"
        ),
        .target(
            name: "SwiftScriptInterpreter",
            dependencies: [
                "SwiftScriptAST",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            path: "Sources/SwiftScriptInterpreter"
        ),
        .executableTarget(
            name: "swift-script",
            dependencies: [
                "SwiftScriptInterpreter",
            ],
            path: "Sources/swift-script"
        ),
        // Real Swift module — same source signature as the interpreter's
        // `MathExtras` bridge, so `import MathExtras` resolves under both
        // stock `swift` (linked dylib) and `swift-script` (interpreter
        // bridge).
        .target(
            name: "MathExtras",
            path: "Sources/MathExtras",
            swiftSettings: [
                // Embed a LC_LINKER_OPTION autolink record into the
                // .swiftmodule so a consumer that does `import MathExtras`
                // also auto-links `libMathExtras` — without this, stock
                // `swift script.swift` (which uses JIT) finds the module
                // but fails to resolve the symbols at run time.
                .unsafeFlags([
                    "-Xfrontend", "-public-autolink-library",
                    "-Xfrontend", "MathExtras",
                ]),
            ]
        ),
        // Generator: reads `swift-symbolgraph-extract` JSON, filters by an
        // allowlist + value-shaped signature predicate, emits Swift bridge
        // code that registers boxing/unboxing wrappers with the interpreter.
        // Run manually for now; future SwiftPM build plugin will invoke
        // this on every clean build.
        .executableTarget(
            name: "BridgeGeneratorTool",
            dependencies: [],
            path: "Sources/BridgeGeneratorTool"
        ),
        .testTarget(
            name: "SwiftScriptInterpreterTests",
            dependencies: ["SwiftScriptInterpreter", "SwiftScriptAST"],
            path: "Tests/SwiftScriptInterpreterTests"
        ),
    ]
)
