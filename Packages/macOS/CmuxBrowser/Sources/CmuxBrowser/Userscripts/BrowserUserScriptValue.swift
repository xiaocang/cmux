import Foundation

/// A JSON-compatible userscript value persisted by cmux.
public enum BrowserUserScriptValue: Codable, Sendable, Equatable {
    /// The JavaScript `null` value.
    case null

    /// A boolean value.
    case bool(Bool)

    /// A numeric value.
    case number(Double)

    /// A string value.
    case string(String)

    /// An ordered array value.
    case array([BrowserUserScriptValue])

    /// A keyed object value.
    case object([String: BrowserUserScriptValue])

    /// Creates a value from a JavaScriptCore/WebKit message object.
    /// - Parameter jsonObject: A property-list-shaped object from WebKit.
    /// - Throws: ``BrowserUserScriptValueError/unsupportedValue`` when the object is not JSON-compatible.
    public init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(BrowserUserScriptValue.init(jsonObject:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(BrowserUserScriptValue.init(jsonObject:)))
        default:
            throw BrowserUserScriptValueError.unsupportedValue
        }
    }

    /// Returns a JSON-compatible object suitable for WebKit replies.
    public var jsonObject: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .number(value):
            return value
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.jsonObject)
        case let .object(values):
            return values.mapValues(\.jsonObject)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BrowserUserScriptValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BrowserUserScriptValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(values):
            try container.encode(values)
        }
    }
}
