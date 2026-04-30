# Four Green Checkmarks: SwiftScript on macOS, iOS, Linux, and Windows

Yesterday afternoon, four little checkmarks lit up next to a commit in
[SwiftScript](https://github.com/Cocoanetics/SwiftScript)'s GitHub Actions:

```
✓ build-macos
✓ build-ios
✓ build-linux
✓ build-windows
```

That's a Swift package — written in Swift, depending on `swift-syntax`,
exposing a Swift API — building **and running its full test suite** on
all four platforms Swift officially supports today. It's the first
project in my catalogue that does that. SwiftBash builds on three.
DTCoreText is Apple-only by definition. SwiftMCP is a server, so Linux
is the second target at most. SwiftScript is the first one where
Windows shows up green next to the rest.

Most of the work to get there had nothing to do with Windows
specifically. It was about taming the auto-generated Foundation bridge
the interpreter uses — which I've written about
[separately](#) — so the same source tree
compiles cleanly against Apple's Foundation overlay, Linux's
swift-corelibs-foundation, and Windows' identical-to-Linux Foundation
build. Once that landed, the CI itself was almost an afterthought.
Almost.

This post is the CI side of the story: what the workflow looks like,
why each platform needs the setup it has, and one weird env-var that
quietly stops your runs from failing every other Tuesday.

## The shape of it

The whole workflow is one file:
[`.github/workflows/swift.yml`](https://github.com/Cocoanetics/SwiftScript/blob/main/.github/workflows/swift.yml).
Four jobs, one per platform, each with a `Build` step and a `Test`
step:

```yaml
name: Swift
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

concurrency:
  group: swift-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-macos:   ...
  build-ios:     ...
  build-linux:   ...
  build-windows: ...
```

Two things at the top earn their keep before any job even starts.

**The concurrency block.** Without `cancel-in-progress: true`, every
push spawns a fresh run while the previous one keeps grinding away.
Windows in particular takes a few minutes from cold cache, and stacking
runs on top of each other wastes both wall-clock time and (if you're
on a paid plan) minutes. The group key includes the ref, so pushes to
*different* branches don't clobber each other — only newer commits on
the same branch do.

**The Node.js env var.** This one took me an embarrassing amount of
time to figure out. As of the GitHub Actions runner image rotation in
spring 2026, Node 20 is being deprecated and Node 16 is gone. Some
older actions still declare `runs.using: node16` in their `action.yml`,
and starting around April the runner began **erroring out** on those
actions instead of warning. The escape hatch is one environment
variable:

```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```

Set it at the workflow level and every JavaScript-based action runs
under Node 24, regardless of what the action's manifest claims. If you
inherited a workflow from before April 2026 and it suddenly started
failing on `actions/checkout` or similar with a Node version error,
this is what you want. (The proper fix is for the action authors to
bump their `runs.using`, but until everyone catches up, the env var is
the seatbelt.)

## macOS: the easy one

```yaml
build-macos:
  runs-on: macos-26
  timeout-minutes: 20
  steps:
    - uses: actions/checkout@v6
    - name: Select Xcode 26.0
      uses: maxim-lobanov/setup-xcode@v1
      with:
        xcode-version: "26.0"
    - name: Verify Swift version
      run: swift --version
    - name: Build (macOS)
      run: swift build --build-tests -v
    - name: Test (macOS)
      run: swift test -v --skip-build
```

`macos-26` is the new GitHub-hosted image (released in early 2026)
that ships with macOS Tahoe 26 and Xcode 26. Until that runner showed
up I was stuck on `macos-latest` — which is still macOS 14 or 15 — and
couldn't actually run the tests, because SwiftScript's package
declares `.macOS("26.0")` and the auto-generated Foundation bridges
call macOS-26-only APIs unconditionally. dyld would refuse to load the
test bundle on the older runner.

Now? `swift build --build-tests` then `swift test --skip-build`.
Splitting build and test into two steps is purely cosmetic — the
Actions UI then shows you exactly where the time is going, which is
helpful when you're tuning. On macOS the whole job takes about 90
seconds.

## iOS: needs an actual simulator

iOS is the platform where you can't get away with `swift build`. Here's
the job:

```yaml
build-ios:
  runs-on: macos-26
  timeout-minutes: 20
  steps:
    - uses: actions/checkout@v6
    - name: Select Xcode 26.0
      uses: maxim-lobanov/setup-xcode@v1
      with:
        xcode-version: "26.0"
    - name: Build (iOS Simulator)
      run: |
        xcodebuild build-for-testing \
          -scheme SwiftScript-Package \
          -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17' \
          -skipPackagePluginValidation
    - name: Test (iOS Simulator)
      run: |
        xcodebuild test-without-building \
          -scheme SwiftScript-Package \
          -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17' \
          -skipPackagePluginValidation
```

A few traps to mention.

**Why `xcodebuild` and not `swift build`?** SwiftPM's `swift build` is
host-only. There's no `--triple arm64-apple-ios` flag in upstream
SwiftPM. Cross-compiling to iOS requires the Xcode toolchain — that's
where the SDK selection, simulator runtimes, and code signing live.
Even if `swift build` could produce an iOS binary, you couldn't *run*
it on macOS without an iOS Simulator runtime, and only Xcode knows how
to manage those. So `xcodebuild` it is.

**Which scheme?** SwiftPM auto-generates an umbrella scheme called
`<PackageName>-Package` that contains every target plus the test
target. The library scheme on its own (`SwiftScriptInterpreter` in our
case) doesn't have a test action defined. If you point `xcodebuild
test` at the library scheme you'll get:

```
xcodebuild: error: Scheme SwiftScriptInterpreter is not currently configured
for the test action.
```

Switch to `-scheme SwiftScript-Package` and it just works.

**`build-for-testing` + `test-without-building`** is the iOS analogue
of `swift build --build-tests` + `swift test --skip-build`. Same
two-step structure, separate timings in the UI, same logical
behaviour.

iOS adds about 60 seconds of simulator warm-up over the macOS time. So
~2.5 minutes total. Not free, but not painful.

## Linux: just give me a container

```yaml
build-linux:
  runs-on: ubuntu-latest
  timeout-minutes: 30
  container:
    image: swift:6.3-jammy
  steps:
    - uses: actions/checkout@v6
    - name: Verify Swift version
      run: swift --version
    - name: Build (Linux)
      run: swift build --build-tests -v
    - name: Test (Linux)
      run: swift test -v --skip-build
```

The official `swift:6.3-jammy` Docker image gives you Swift 6.3 on
Ubuntu 22.04 with everything pre-installed. No setup steps, no apt
faff, no toolchain install. Run `swift --version` to confirm and you're
already done.

The version pin matters more than it looks. SwiftScript's bridge
generator extracts a "what's available on the cross-platform side"
oracle from a checkout of `swift-corelibs-foundation`, which itself
pulls in `swift-foundation` as a dependency. Whatever revision of
`swift-foundation` ships in your Linux toolchain has to be at least as
new as what the oracle was generated from — otherwise you'll get
`type 'X' has no member 'Y'` errors on perfectly-fresh-looking code.
`swift:6.0-jammy` was too old. `swift:6.3-jammy` lines up.

Linux finishes in about 3.5 minutes — slower than macOS because of
container pull, but the whole `swift build --build-tests` cycle is a
clean cold compile every time.

## Windows: the one everyone is afraid of

This is the one I expected to be the rabbit hole. It wasn't, in the
end, but there were two false starts.

```yaml
build-windows:
  runs-on: windows-latest
  timeout-minutes: 45
  steps:
    - uses: actions/checkout@v6
    - name: Setup Swift
      uses: SwiftyLab/setup-swift@latest
      with:
        swift-version: "6.3.1"
    - name: Verify Swift version
      run: swift --version
    - name: Build (Windows)
      run: swift build --build-tests -v
    - name: Test (Windows)
      run: swift test -v --skip-build
```

**The toolchain installer.** I started with the long-time go-to,
[`compnerd/gha-setup-swift`](https://github.com/compnerd/gha-setup-swift).
It works, but pinning to Swift 6.0.3 hit a now-known issue:
`swift-syntax` failed to compile on the Windows runner with `cyclic
dependency in module 'ucrt'`. That's a clash between Swift's `ucrt`
module shim and the bundled MSVC headers, fixed in 6.3. The
development snapshots that *had* the fix were unreliable on the
hosted runner — sometimes they'd install, sometimes they'd 404.

Then I switched to
[`SwiftyLab/setup-swift`](https://github.com/marketplace/actions/setup-swift-environment-for-macos-linux-and-windows).
This is the unified macOS / Linux / Windows installer that gets less
attention than it deserves. Pinning to `swift-version: "6.3.1"` gave
me a reliable install in about 90 seconds, every time. No
visual-studio-component dance, no cache configuration. (The action's
README says toolchain caching is *not* supported on Windows for Swift
5.10+, so I tried adding an `actions/cache` for `.build/`. It didn't
help enough to justify the extra step — install + first compile is
already faster than the cache thrash.)

**Patch-level pin matters.** The first time I had `swift-version:
"6.3"` and the action resolved that to a slightly different snapshot
between runs. Pinning the patch (`"6.3.1"`) makes the toolchain
identical run-to-run, which keeps the cache key stable on the
*action's* internal cache and makes the install genuinely
deterministic.

The full Windows job — toolchain install, swift-syntax compile, every
bridge file, plus `swift test` — runs in about 8 minutes from a cold
runner. The first time it ran, it took fourteen. The
`cancel-in-progress` block at the top of the workflow really earns its
keep here.

## Recommended setup, condensed

If you're starting a fresh Swift package today and want all four
platforms green, here's the shortest version of the recipe that
actually works in late April 2026:

| Platform | Runner | Toolchain step | Build/test |
|---|---|---|---|
| macOS  | `macos-26`     | `maxim-lobanov/setup-xcode@v1` (Xcode 26) | `swift build --build-tests` + `swift test --skip-build` |
| iOS    | `macos-26`     | same                                       | `xcodebuild build-for-testing` + `xcodebuild test-without-building`, scheme `SwiftScript-Package`, simulator destination |
| Linux  | `ubuntu-latest` + `container: swift:6.3-jammy` | none (image-provided) | `swift build --build-tests` + `swift test --skip-build` |
| Windows | `windows-latest` | `SwiftyLab/setup-swift@latest`, `swift-version: "6.3.1"` | `swift build --build-tests` + `swift test --skip-build` |

Plus the two workflow-level helpers:

```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

concurrency:
  group: swift-${{ github.ref }}
  cancel-in-progress: true
```

A few rules of thumb that fall out of the table:

- **Pin Swift versions to a patch number on Windows.** Floating tags
  there cost you cache hits and reproducibility.
- **Don't overthink Windows caching.** SwiftyLab's installer is fast
  enough that `actions/cache` for `.build/` has a poor cost/benefit
  ratio. The first commit's run is your honest cold-start time.
- **Split build and test.** The two-step pattern matches across all
  four platforms and gives you precise timings in the UI without
  changing semantics.
- **Use the SwiftPM umbrella scheme on iOS.** Don't waste time
  configuring a custom test target in Xcode — SwiftPM already
  generates `<Package>-Package` for you.

## The one weird thing about Apple platforms

Notice that macOS and iOS both run on `macos-26`, but only macOS uses
`swift build`. iOS goes through `xcodebuild`. That's not a workflow
choice — it's a SwiftPM limitation. SwiftPM compiles for the host
platform and only the host platform. On a Mac runner the host is
macOS. There's no `swift build --triple arm64-apple-ios` because there's
no host that *is* iOS.

Xcode papers over this by knowing how to drive SwiftPM with the
correct SDK and how to spin up a simulator to run the result. If
you've ever wondered why `xcodebuild` exists alongside `swift build`,
this is the moment that answers it. On Linux and Windows the host
*is* the deployment target, so `swift build` is enough. On
non-Mac Apple platforms (iOS, watchOS, tvOS, visionOS), you cross-
compile through Xcode, full stop.

## What's next

The CI workflow itself is now boring, which is what you want from CI.
The next thing to make boring is the bridge generator's regen step:
right now refreshing the cross-platform symbol oracle requires a local
checkout of `swift-corelibs-foundation`. I'd like that to happen on
its own in a scheduled GitHub Actions job, so the auto-generated
bridges always track the real Linux Foundation surface without me
remembering to refresh.

But that's tomorrow. Today, four green checkmarks.
