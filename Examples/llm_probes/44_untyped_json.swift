// Untyped JSON via JSONSerialization — read unknown shapes, walk
// them with as?, write them back.
import Foundation

let raw = #"{"name": "widget", "tags": ["a", "b"], "count": 3, "price": 9.5, "ok": true, "gone": null}"#
let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8))
let dict = obj as? [String: Any]
print(dict?["name"] as? String ?? "?")
print(dict?["count"] as? Int ?? -1)
print(dict?["price"] as? Double ?? -1.0)
print(dict?["ok"] as? Bool ?? false)
print((dict?["tags"] as? [String])?.joined(separator: "+") ?? "?")
let out = try JSONSerialization.data(withJSONObject: ["only": [1, 2, 3]])
print(String(data: out, encoding: .utf8)!)
