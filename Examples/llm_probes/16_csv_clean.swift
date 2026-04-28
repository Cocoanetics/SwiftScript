// LLM idiom: parse a comma-separated string, trim whitespace from each
// field. Exercises components(separatedBy:) and trimmingCharacters(in:).
import Foundation

let raw = "  alice ,  bob,carol  ,  dave"
let cleaned = raw
    .components(separatedBy: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }

for name in cleaned {
    print(name)
}

// Also split on a CharacterSet — split a phone number on punctuation.
let phone = "+1 (555) 123-4567"
let digits = phone
    .components(separatedBy: .punctuationCharacters)
    .joined()
    .components(separatedBy: .whitespaces)
    .joined()
print(digits)
