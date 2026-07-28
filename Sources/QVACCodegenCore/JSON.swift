import Foundation

/// A minimal JSON model for reading the contract artifacts.
///
/// `JSONSerialization` under the hood; the only subtlety is telling booleans
/// apart from numbers, which `NSNumber` obscures — `objCType == "c"` is the
/// portable tell on both Darwin and corelibs-foundation.
public indirect enum JSON: Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public static func parse(_ data: Data) throws -> JSON {
        try convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func convert(_ value: Any) throws -> JSON {
        switch value {
        case let dictionary as [String: Any]:
            var out: [String: JSON] = [:]
            out.reserveCapacity(dictionary.count)
            for (key, element) in dictionary { out[key] = try convert(element) }
            return .object(out)
        case let array as [Any]:
            return .array(try array.map(convert))
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if String(cString: number.objCType) == "c" { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case is NSNull:
            return .null
        default:
            throw CodegenError.malformedContract("unrepresentable JSON value: \(value)")
        }
    }

    // MARK: - Accessors

    public subscript(key: String) -> JSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var objectValue: [String: JSON]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

public enum CodegenError: Swift.Error, CustomStringConvertible {
    case malformedContract(String)
    case unsupportedSchema(String, at: String)
    case nameCollision(name: String, first: String, second: String)

    public var description: String {
        switch self {
        case .malformedContract(let detail):
            return "malformed contract: \(detail)"
        case .unsupportedSchema(let detail, let path):
            return "unsupported schema construct at \(path): \(detail)"
        case .nameCollision(let name, let first, let second):
            return "two different schemas want the name '\(name)': \(first) vs \(second) — retitle upstream or qualify by parent path"
        }
    }
}
