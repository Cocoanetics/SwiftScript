import Foundation

let principal = 1000.0
let rate = 0.05
let years = 10

var balance = principal
for year in 1...years {
    balance *= (1 + rate)
    print(String(format: "year %2d: %8.2f", year, balance))
}
