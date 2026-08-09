// The stock regex idiom: range(of:options:) + slicing + regex replace.
import Foundation

let log = "user=alice id=4711 action=login"
if let idRange = log.range(of: "id=[0-9]+", options: .regularExpression) {
    print(String(log[idRange]))
}
print(log.range(of: "id=[a-z]+", options: .regularExpression) == nil)
print("a1b22c333".replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression))
print("Hello".range(of: "l") != nil)
