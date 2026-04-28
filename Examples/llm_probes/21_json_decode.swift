// LLM idiom: parse JSON received from elsewhere into typed structs.
import Foundation

struct Pet: Codable {
    let species: String
    let age: Int
}

struct Owner: Codable {
    let name: String
    let pets: [Pet]
    let address: String?
}

let json = """
{
    "name": "Diana",
    "address": "221B Baker St",
    "pets": [
        { "species": "cat", "age": 3 },
        { "species": "parrot", "age": 12 }
    ]
}
"""

let data = Data(json.utf8)
let owner = try JSONDecoder().decode(Owner.self, from: data)
print(owner.name)
print(owner.address ?? "(no address)")
for pet in owner.pets {
    print("- \(pet.species), age \(pet.age)")
}

// Optional handling: address missing.
let json2 = "{\"name\":\"Eve\",\"pets\":[]}"
let owner2 = try JSONDecoder().decode(Owner.self, from: Data(json2.utf8))
print(owner2.name, "has no pets:", owner2.pets.isEmpty)
print(owner2.address ?? "(no address)")
