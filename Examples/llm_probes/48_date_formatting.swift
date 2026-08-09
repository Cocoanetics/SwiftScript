// DateFormatter / ISO8601DateFormatter — parse and format with
// fixed timezone + locale so both runtimes print identical text.
import Foundation

let df = DateFormatter()
df.locale = Locale(identifier: "en_US_POSIX")
df.timeZone = TimeZone(identifier: "UTC")
df.dateFormat = "yyyy-MM-dd HH:mm"
let parsed = df.date(from: "2026-08-09 14:30")!
print(df.string(from: parsed))
print(parsed.timeIntervalSince1970)

let iso = ISO8601DateFormatter()
print(iso.string(from: Date(timeIntervalSince1970: 86_400)))
let back = iso.date(from: "2001-01-01T00:00:00Z")!
print(back.timeIntervalSinceReferenceDate)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
struct Stamp: Codable { let at: Date }
print(String(data: try encoder.encode(Stamp(at: back)), encoding: .utf8)!)
