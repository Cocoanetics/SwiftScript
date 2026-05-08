import Foundation
import ShellKit

// MARK: - Host hooks for sandboxing
//
// SwiftScript runs against `ShellKit.Shell.current` so embedders can
// confine script I/O without forking the bridge generator. The
// auto-generated Foundation bridges (FileManager, URLSession,
// ProcessInfo) and the hand-rolled ones (`String.write(to:)`,
// `Data(contentsOf:)`, …) call into these top-level functions before
// touching disk / network / identity.
//
// Default behaviour: each gate reads from
// ``ShellKit/Shell/current``. An embedder that wants confinement just
// constructs a ``ShellKit/Shell`` with a `sandbox` / `networkConfig`
// / `hostInfo` and binds it via ``ShellKit/Shell/withCurrent(_:)``.
// Standalone (`swift-script` CLI) sees ``ShellKit/Shell/processDefault``
// — `nil` sandbox, no network policy, real `HostInfo` — so the gates
// are no-ops and the binary behaves as it always did.

// MARK: Filesystem

/// Hint about why a path is being authorized. Embedders may use the
/// kind to apply different rules per intent (e.g. allow read-only
/// access to system frameworks but deny writes).
public enum PathAccessIntent: Sendable {
    case read
    case write
    case delete
}

/// Authorize a filesystem access against the bound shell's sandbox.
///
/// Throws ``ShellKit/Sandbox/Denial`` (rethrown as a
/// ``UserThrowSignal`` from the bridge wrapper) when the bound
/// sandbox rejects the path. Returns silently when no sandbox is
/// bound.
@inlinable
public func authorizePath(
    _ path: String,
    for intent: PathAccessIntent = .read
) async throws {
    _ = intent  // reserved for future per-intent rules
    guard let sandbox = ShellKit.Shell.current.sandbox else { return }
    try await sandbox.authorize(URL(fileURLWithPath: path))
}

/// URL-form variant for bridges that get a `URL` arg rather than a
/// path string. Foundation URL types include both `file://` and
/// scheme-bearing URLs; the same `Sandbox.authorize(_:)` handles
/// both.
@inlinable
public func authorizePath(
    _ url: URL,
    for intent: PathAccessIntent = .read
) async throws {
    _ = intent
    guard let sandbox = ShellKit.Shell.current.sandbox else { return }
    try await sandbox.authorize(url)
}

// MARK: Network

/// Authorize a network access against the bound shell's `sandbox`
/// host gate and `networkConfig` allow-list.
///
/// Throws when either policy denies the URL/method. Returns silently
/// when neither is configured (the standalone-CLI passthrough).
@inlinable
public func authorizeURL(
    _ url: URL,
    method: String = "GET"
) async throws {
    if let sandbox = ShellKit.Shell.current.sandbox {
        try await sandbox.authorize(url)
    }
    if let config = ShellKit.Shell.current.networkConfig {
        try config.checkAllowed(url: url, method: method)
    }
}

// MARK: Identity

/// Synthetic user-name override — script-side `ProcessInfo
/// .processInfo.userName` reads this. Standalone mode reports the
/// real OS account; under an embedder it reflects the bound
/// `HostInfo.userName`.
@inlinable
public func hostUserName() -> String {
    ShellKit.Shell.current.hostInfo.userName
}

/// Synthetic full-user-name. ShellKit's `HostInfo` doesn't carry a
/// distinct GECOS field so we surface `userName` here too — embedders
/// that care can layer richer identity on top.
@inlinable
public func hostFullUserName() -> String {
    ShellKit.Shell.current.hostInfo.userName
}

/// Synthetic host-name — `ProcessInfo.processInfo.hostName`.
@inlinable
public func hostNameOverride() -> String {
    ShellKit.Shell.current.hostInfo.hostName
}

/// Synthetic process identifier — `ProcessInfo.processInfo
/// .processIdentifier` reads `Shell.virtualPID`, which defaults to
/// 1 under a sandbox embedder and to the real PID under
/// `Shell.processDefault`.
@inlinable
public func hostProcessIdentifier() -> Int32 {
    ShellKit.Shell.current.virtualPID
}

/// Synthetic process name — falls back to the script's `$0`
/// (`Shell.scriptName`) so a running script that introspects
/// `ProcessInfo.processInfo.processName` sees the file it's
/// executing, not the embedder's binary.
@inlinable
public func hostProcessName() -> String {
    let name = ShellKit.Shell.current.scriptName
    if !name.isEmpty { return name }
    // Last-resort fallback for the synthetic-identity case where
    // an embedder constructs a Shell without setting scriptName.
    return ShellKit.Shell.current.hostInfo.userName
}

/// Synthetic environment dict — `ProcessInfo.processInfo
/// .environment`. Routed through ``ShellKit/Shell/current``'s
/// `Environment` so a script that reads its own env sees what the
/// embedder set, not the host process's actual env.
@inlinable
public func hostEnvironment() -> [String: String] {
    ShellKit.Shell.current.environment.variables
}

/// Synthetic argv — `ProcessInfo.processInfo.arguments`. Mirrors
/// the same source `CommandLine.arguments` reads from. See
/// ``Interpreter/scriptArguments`` for the full layering.
@inlinable
public func hostProcessArguments() -> [String] {
    let shell = ShellKit.Shell.current
    var assembled = [shell.scriptName]
    assembled.append(contentsOf: shell.positionalParameters)
    if assembled == [""] { return [] }
    return assembled
}

// MARK: NetworkConfig allow-list helper

extension ShellKit.NetworkConfig {
    /// Throw when this `NetworkConfig` denies access to `url` /
    /// `method`. Mirrors the policy SwiftBash's `curl` builtin
    /// applies. Pulled out as a method here so the SwiftScript
    /// network bridges can share the same enforcement.
    @usableFromInline
    func checkAllowed(url: URL, method: String) throws {
        if dangerouslyAllowFullInternetAccess { return }
        // Method gate.
        let normalised = method.uppercased()
        let knownMethod = HTTPMethod(rawValue: normalised) ?? .GET
        if !allowedMethods.contains(knownMethod) {
            throw NetworkAccessDenied(
                url: url,
                reason: "HTTP method \(normalised) not in allow-list")
        }
        // URL allow-list — ShellKit's matcher applies the same
        // wildcard / origin-only / path-scoped semantics SwiftBash
        // uses for `curl`.
        let allowed = URLAllowList.isAllowed(
            url.absoluteString,
            entries: allowedURLPrefixes)
        guard allowed else {
            throw NetworkAccessDenied(
                url: url, reason: "URL not in allow-list")
        }
    }

    public struct NetworkAccessDenied: Error, CustomStringConvertible {
        public let url: URL
        public let reason: String
        public var description: String {
            "Network access denied: \(reason): \(url.absoluteString)"
        }
    }
}
