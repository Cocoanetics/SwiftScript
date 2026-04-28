// LLM idiom: parse a URL, pull out its parts, build a related one.
import Foundation

let url = URL(string: "https://example.com:8080/path/to/page.html?q=swift#top")!
print(url.scheme ?? "(no scheme)")
print(url.host ?? "(no host)")
print(url.path)
print(url.lastPathComponent)
print(url.pathExtension)
print(url.query ?? "(no query)")
print(url.fragment ?? "(no fragment)")

// Failable init returns nil on garbage input.
if URL(string: "") == nil {
    print("empty string yields nil")
}

// Build a related URL by appending a path component.
let base = URL(string: "https://example.com/api")!
let next = base.appendingPathComponent("v1").appendingPathComponent("users")
print(next.absoluteString)

// File URL — path-based init is non-failable.
let file = URL(fileURLWithPath: "/tmp/foo.txt")
print(file.isFileURL)
print(file.lastPathComponent)
