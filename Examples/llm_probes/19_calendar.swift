// LLM idiom: extract calendar components, build a date, advance by N days.
import Foundation

let cal = Calendar.current
let epoch = Date(timeIntervalSince1970: 0)

// Single-component getters in UTC-ish terms (depends on Calendar.current).
let year = cal.component(Calendar.Component.year, from: epoch)
let month = cal.component(Calendar.Component.month, from: epoch)
print("epoch year/month:", year, month)

// Multi-component getter via array.
let parts = cal.dateComponents([Calendar.Component.year, Calendar.Component.month, Calendar.Component.day], from: epoch)
print("year:", parts.year ?? -1)
print("month:", parts.month ?? -1)
print("day:", parts.day ?? -1)

// Construct a date from components.
var dc = DateComponents(year: 2024, month: 1, day: 15)
if let built = cal.date(from: dc) {
    let y = cal.component(Calendar.Component.year, from: built)
    let m = cal.component(Calendar.Component.month, from: built)
    let d = cal.component(Calendar.Component.day, from: built)
    print("built:", y, m, d)
}

// Advance by 7 days.
let plus7 = cal.date(byAdding: Calendar.Component.day, value: 7, to: epoch)!
let interval = plus7.timeIntervalSince(epoch)
print("interval after 7 days:", interval)
