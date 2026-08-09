// Waiting is the primitive polling loops are built on (issue #7's
// top-ranked gap). Sleep must actually suspend.
import Foundation

let started = Date()
var polls = 0
while polls < 3 {
    try await Task.sleep(nanoseconds: 20_000_000)
    polls += 1
}
print(polls)
print(Date().timeIntervalSince(started) >= 0.05)
