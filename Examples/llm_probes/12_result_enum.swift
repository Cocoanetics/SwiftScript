// LLM idiom: a small Result-like enum used to thread parse outcomes.

enum ParseOutcome {
    case number(Double)
    case error(String)
}

func parse(_ s: String) -> ParseOutcome {
    if let d = Double(s) { return .number(d) }
    return .error("not a number: \(s)")
}

let inputs = ["3.14", "hello", "42", ""]
for x in inputs {
    switch parse(x) {
    case .number(let n): print("ok: \(n)")
    case .error(let m): print("err: \(m)")
    }
}
