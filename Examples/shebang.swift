#!/usr/bin/env swift-script

// A real script: run with `chmod +x shebang.swift && ./shebang.swift`.

let radius = 5.0
let area = Double.pi * radius * radius
print(String(format: "circle r=%.1f area=%.4f", radius, area))

let nums = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3]
let sorted = nums.sorted()
print("sorted:", sorted)
print("min:   ", nums.min()!)
print("max:   ", nums.max()!)
print("sum:   ", nums.reduce(0, +))
print("mean:  ", String(format: "%.2f", Double(nums.reduce(0, +)) / Double(nums.count)))
