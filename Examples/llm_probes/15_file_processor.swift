// LLM idiom: small file processor — read/transform/write.
import Foundation

let inputPath  = "/tmp/_ssp_in.txt"
let outputPath = "/tmp/_ssp_out.txt"

// Set up: write a short file with some lines.
try [
    "alpha",
    "beta",
    "gamma",
    "delta",
].joined(separator: "\n").write(toFile: inputPath, atomically: true, encoding: .utf8)

// Process: read, uppercase each line, sort, rejoin.
let raw = try String(contentsOfFile: inputPath, encoding: .utf8)
let upperSorted = raw
    .split(separator: "\n")
    .map { String($0).uppercased() }
    .sorted()
    .joined(separator: ",")

// Write output and report.
try upperSorted.write(toFile: outputPath, atomically: true, encoding: .utf8)
print(try String(contentsOfFile: outputPath, encoding: .utf8))

// Cleanup.
try FileManager.default.removeItem(atPath: inputPath)
try FileManager.default.removeItem(atPath: outputPath)
