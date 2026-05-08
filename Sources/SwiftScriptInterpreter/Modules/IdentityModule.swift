import Foundation
import ShellKit

/// Hand-rolled identity overrides — the auto-generator only catches
/// the simply-typed `ProcessInfo` properties (`hostName`,
/// `processName`). The ones with non-`Int`-shaped or array-shaped
/// types (`processIdentifier: Int32`, `arguments: [String]`,
/// `environment: [String: String]`) are bridged here, all redirected
/// to the bound shell's `HostInfo` / `Environment` / `scriptName`
/// via the helpers in `HostHooks.swift`.
///
/// Loaded alongside the rest of the Foundation surface so a script
/// that imports Foundation (or Darwin / Glibc / ucrt / WinSDK) sees
/// the synthetic identity automatically.
struct IdentityModule: BuiltinModule {
    // Distinct from `FoundationModule.name == "Foundation"` so
    // `register(module:)`'s idempotency check (`registeredModules`)
    // doesn't drop us when both modules try to register on
    // `import Foundation`.
    let name = "ProcessInfoIdentity"

    func register(into i: Interpreter) {
        // `ProcessInfo.userName` and `.fullUserName` — neither makes
        // it through the generator (Foundation surfaces them as a
        // platform-conditional pair on Apple). Map both to
        // `hostUserName()` so a sandbox embedder can present a
        // synthetic account.
        i.bridges["var ProcessInfo.userName: String"] = .computed { _ in
            return .string(hostUserName())
        }
        i.bridges["var ProcessInfo.fullUserName: String"] = .computed { _ in
            return .string(hostFullUserName())
        }

        // `ProcessInfo.processIdentifier: Int32` — the generator
        // skips Int32; we bridge it here, surfacing it as `Int` to
        // the script (the only integer type SwiftScript bridges).
        i.bridges["var ProcessInfo.processIdentifier: Int"] = .computed { _ in
            return .int(Int(hostProcessIdentifier()))
        }

        // `ProcessInfo.arguments: [String]` and
        // `ProcessInfo.environment: [String: String]` — array and
        // dictionary shapes the generator doesn't auto-bridge.
        i.bridges["var ProcessInfo.arguments: [String]"] = .computed { _ in
            return .array(hostProcessArguments().map { .string($0) })
        }
        i.bridges["var ProcessInfo.environment: [String: String]"] = .computed { _ in
            let dict = hostEnvironment()
            return .dict(dict.map { (k, v) in
                DictEntry(key: .string(k), value: .string(v))
            })
        }
    }
}
