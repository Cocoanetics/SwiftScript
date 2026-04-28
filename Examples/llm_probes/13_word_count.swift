// LLM idiom: count word occurrences using a dict.

let text = "the quick brown fox jumps over the lazy dog the fox"
var counts = [String: Int]()
for word in text.lowercased().split(separator: " ") {
    let key = String(word)
    counts[key] = (counts[key] ?? 0) + 1
}

for (word, n) in counts.sorted(by: { $0.key < $1.key }) {
    print("\(word): \(n)")
}
