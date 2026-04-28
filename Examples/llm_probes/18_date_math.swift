// LLM idiom: arithmetic with Date and TimeInterval.
import Foundation

let epoch = Date(timeIntervalSince1970: 0)
print(epoch.timeIntervalSince1970)

let later = Date(timeIntervalSince1970: 86400) // one day
let interval = later.timeIntervalSince(epoch)
print(interval)

// Add an interval and check the round-trip.
let plusHour = epoch.addingTimeInterval(3600)
print(plusHour.timeIntervalSince1970)

// Distance between two dates is the same as timeIntervalSince.
print(epoch.distance(to: later))
