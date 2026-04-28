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
