// Throwing-method bridges generated automatically: the Swift error is
// caught at the bridge boundary and re-raised as a UserThrowSignal so
// script-side `do/catch` blocks can match.
//
// We probe via `URL.checkResourceIsReachable()` which throws a Cocoa
// error on a non-existent file. To keep the comparison stable we don't
// print the underlying error (the message contains pointer addresses
// that differ across runs); we just print whether the catch fired and
// the success-path return.
import Foundation

let bad = URL(fileURLWithPath: "/this/should/not/exist/for-real-987")
do {
    _ = try bad.checkResourceIsReachable()
    print("missing path appeared reachable??")
} catch {
    print("missing-path catch fired")
}

let tmp = URL(fileURLWithPath: "/tmp")
do {
    let ok = try tmp.checkResourceIsReachable()
    print("tmp reachable:", ok)
} catch {
    print("tmp failed:")
}
