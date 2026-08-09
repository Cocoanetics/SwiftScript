// POST-shaped URLRequest and HTTPURLResponse casting, no network.
import Foundation

var request = URLRequest(url: URL(string: "https://example.com/api/items")!)
request.httpMethod = "POST"
request.httpBody = Data(#"{"q": 1}"#.utf8)
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
print(request.httpMethod!)
print(request.url!.absoluteString)
print(request.httpBody!.count)
print(request.value(forHTTPHeaderField: "Content-Type")!)

let response: URLResponse = HTTPURLResponse(
    url: URL(string: "https://example.com/api/items")!,
    statusCode: 201, httpVersion: nil, headerFields: nil)!
if let http = response as? HTTPURLResponse {
    print(http.statusCode)
}
print(response is HTTPURLResponse)
