import Foundation

// MARK: - JSONValue

/// Minimal JSON model so we can round-trip arbitrary params/results without
/// pulling in a dependency.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // Convenience accessors
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - RequestID

/// JSON-RPC ids may be numbers or strings.
public enum RequestID: Codable, Sendable, Equatable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "id must be a number or string")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

// MARK: - Request / Response

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    /// nil id = notification (no response expected).
    public let id: RequestID?
    public let method: String
    public let params: JSONValue?

    public init(id: RequestID?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func parseError(_ message: String = "Parse error") -> JSONRPCError { .init(code: -32700, message: message) }
    public static func methodNotFound(_ method: String) -> JSONRPCError { .init(code: -32601, message: "Method not found: \(method)") }
    public static func invalidParams(_ message: String) -> JSONRPCError { .init(code: -32602, message: message) }
    public static func internalError(_ message: String) -> JSONRPCError { .init(code: -32603, message: message) }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: RequestID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: RequestID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RequestID?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        // id must be present (null for parse errors on unidentifiable requests).
        if let id { try container.encode(id, forKey: .id) } else { try container.encodeNil(forKey: .id) }
        if let result { try container.encode(result, forKey: .result) }
        if let error { try container.encode(error, forKey: .error) }
    }
}
