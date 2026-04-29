import Testing
@testable import SwiftScriptInterpreter

@Suite("Signature parser")
struct SignatureTests {

    @Test func parses_plain_method() throws {
        let s = try Signature.parse("func URL.absoluteString() -> String")
        #expect(s.kind == .method)
        #expect(s.receiver == "URL")
        #expect(s.memberName == "absoluteString")
        #expect(s.parameters.isEmpty)
        #expect(s.returnType == "String")
        #expect(s.generics.isEmpty)
        #expect(!s.isThrowing)
    }

    @Test func parses_throwing_method_with_label() throws {
        let s = try Signature.parse("func URLSession.data(from: URL) async throws -> Data")
        #expect(s.kind == .method)
        #expect(s.receiver == "URLSession")
        #expect(s.memberName == "data")
        #expect(s.parameters.count == 1)
        #expect(s.parameters[0].label == "from")
        #expect(s.parameters[0].type == "URL")
        #expect(s.isThrowing)
        #expect(s.returnType == "Data")
    }

    @Test func parses_generic_method_with_constraint() throws {
        let s = try Signature.parse("func JSONEncoder.encode<T: Encodable>(_: T) throws -> Data")
        #expect(s.kind == .method)
        #expect(s.receiver == "JSONEncoder")
        #expect(s.memberName == "encode")
        #expect(s.generics.count == 1)
        #expect(s.generics[0].name == "T")
        #expect(s.generics[0].constraints == ["Encodable"])
        #expect(s.parameters.count == 1)
        #expect(s.parameters[0].label == nil)
        #expect(s.parameters[0].type == "T")
        #expect(s.isThrowing)
        #expect(s.returnType == "Data")
        #expect(s.isGeneric)
    }

    @Test func parses_generic_method_with_metatype_param() throws {
        let s = try Signature.parse("func JSONDecoder.decode<T: Decodable>(_: T.Type, from: Data) throws -> T")
        #expect(s.generics[0].constraints == ["Decodable"])
        #expect(s.parameters[0].type == "T.Type")
        #expect(s.parameters[1].label == "from")
        #expect(s.parameters[1].type == "Data")
        #expect(s.returnType == "T")
    }

    @Test func parses_init() throws {
        let s = try Signature.parse("init URL(string: String)")
        #expect(s.kind == .`init`)
        #expect(s.receiver == "URL")
        #expect(s.parameters.count == 1)
        #expect(s.parameters[0].label == "string")
        #expect(s.parameters[0].type == "String")
        #expect(!s.isFailable)
    }

    @Test func parses_failable_init() throws {
        let s = try Signature.parse("init URL?(string: String)")
        #expect(s.isFailable)
    }

    @Test func parses_computed_property() throws {
        let s = try Signature.parse("var URL.absoluteString: String")
        #expect(s.kind == .computed)
        #expect(s.receiver == "URL")
        #expect(s.memberName == "absoluteString")
        #expect(s.returnType == "String")
    }

    @Test func parses_static_value() throws {
        let s = try Signature.parse("static let Int.max: Int")
        #expect(s.kind == .staticValue)
        #expect(s.receiver == "Int")
        #expect(s.memberName == "max")
        #expect(s.returnType == "Int")
    }

    @Test func parses_static_method_with_generics() throws {
        let s = try Signature.parse("static func Int.random<T: BinaryInteger>(in: Range<T>) -> T")
        #expect(s.kind == .staticMethod)
        #expect(s.generics.count == 1)
        #expect(s.generics[0].constraints == ["BinaryInteger"])
        #expect(s.parameters[0].type.contains("Range<T>"))
        #expect(s.returnType == "T")
    }

    @Test func parses_where_clause_constraints() throws {
        let s = try Signature.parse("func Set.union<S>(_: S) -> Set where S: Sequence")
        #expect(s.generics[0].name == "S")
        #expect(s.generics[0].constraints == ["Sequence"])
    }
}
