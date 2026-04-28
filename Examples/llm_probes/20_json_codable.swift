// LLM idiom: define a struct, encode to JSON, decode back, print fields.
//
// We assert on the round-trip semantics (decoded values match the original
// fields) rather than the encoded byte sequence, because Swift's
// `JSONEncoder` doesn't promise a key order and matching would require
// setting `outputFormatting = .sortedKeys` which our interpreter doesn't
// surface. The decoded values are deterministic regardless.
import Foundation

struct User: Codable {
    let name: String
    let age: Int
    let isAdmin: Bool
    let nickname: String?
}

let alice = User(name: "Alice", age: 30, isAdmin: true, nickname: "Al")
let bob = User(name: "Bob", age: 25, isAdmin: false, nickname: nil)

let encoder = JSONEncoder()
let aliceData = try encoder.encode(alice)
let bobData = try encoder.encode(bob)

// Round-trip back to a User.
let decoder = JSONDecoder()
let aliceCopy = try decoder.decode(User.self, from: aliceData)
print(aliceCopy.name, aliceCopy.age, aliceCopy.isAdmin)
print(aliceCopy.nickname ?? "(no nickname)")

let bobCopy = try decoder.decode(User.self, from: bobData)
print(bobCopy.name, bobCopy.age, bobCopy.isAdmin)
print(bobCopy.nickname ?? "(no nickname)")

// Nested structs round-trip too.
struct Team: Codable {
    let name: String
    let members: [User]
}

let team = Team(name: "Engineering", members: [alice, bob])
let teamData = try encoder.encode(team)
let teamCopy = try decoder.decode(Team.self, from: teamData)
print(teamCopy.name, "has", teamCopy.members.count, "members")
for m in teamCopy.members {
    print(" -", m.name)
}
