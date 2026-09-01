import Foundation

/// A request frame on the stdin/stdout protocol.
public struct Request: Codable {
    public let id: Int
    public let method: String
    public let params: JSONValue

    public static func decode(from data: Data) throws -> Request {
        try JSONDecoder().decode(Request.self, from: data)
    }
}

/// A response frame on the stdin/stdout protocol.
public struct Response: Codable {
    public let id: Int
    public let ok: Bool
    public let result: JSONValue?
    public let error: ErrorBody?

    public struct ErrorBody: Codable {
        public let code: String
        public let message: String
    }

    public static func ok(id: Int, result: JSONValue) -> Response {
        Response(id: id, ok: true, result: result, error: nil)
    }

    public static func failure(id: Int, code: String, message: String) -> Response {
        Response(id: id, ok: false, result: nil, error: ErrorBody(code: code, message: message))
    }

    public func encode() -> Data {
        try! JSONEncoder().encode(self)
    }
}

/// A JSON value that survives round-tripping through the protocol.
public enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Converts any `Encodable` value into a `JSONValue`, so a `Codable` struct can be
    /// embedded in a `Response` result without hand-building the tree.
    public static func encode<T: Encodable>(_ value: T) -> JSONValue {
        let data = try! JSONEncoder().encode(value)
        return try! JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
