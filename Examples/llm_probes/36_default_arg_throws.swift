// `Data(contentsOf:)` was previously skipped because the symbol graph
// surfaces only `Data(contentsOf:options:)` where `options:
// ReadingOptions` defaults to `[]`. The generator now drops defaulted-
// and-unbridgeable params, so the 1-arg form bridges with `options`
// implicitly defaulted to `[]`.
//
// We exercise both the throw path (missing file) and the success path
// (read a file we wrote).
import Foundation

// Throw path.
let bad = URL(fileURLWithPath: "/this/should/not/exist/data-probe-987")
do {
    _ = try Data(contentsOf: bad)
    print("unexpectedly succeeded")
} catch {
    print("Data(contentsOf:) caught error on missing file")
}

// Success path: write hello, read back, byte-count check.
let tmp = URL(fileURLWithPath: "/tmp/swiftscript-data-probe.txt")
do {
    try "hello".write(to: tmp, atomically: true, encoding: .utf8)
    let data = try Data(contentsOf: tmp)
    print("byte count:", data.count)
    let s = String(data: data, encoding: .utf8) ?? "(decode failed)"
    print("contents:", s)
} catch {
    print("io chain failed:")
}
