import Foundation

/// Compact UTF-8 JSON. Object keys are sorted so a manifest hash matches the Android writer.
enum JSONWire {
    static let metadataLimit = 32 * 1024 * 1024

    static func encode(_ value: JSONValue) -> Data {
        Data(encodeString(value).utf8)
    }

    static func parse(_ data: Data, path: String) throws -> JSONValue {
        if data.count > metadataLimit {
            throw ContractError(path: path, message: "Metadata exceeds 32 MiB.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ContractError(path: path, message: "Expected UTF-8 JSON.")
        }
        var parser = Parser(text: text, path: path)
        let value = try parser.parseValue()
        parser.skipSpace()
        if !parser.isAtEnd {
            throw ContractError(path: path, message: "Invalid JSON.")
        }
        return value
    }

    static func encodeString(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .string(let text):
            return quote(text)
        case .array(let items):
            return "[" + items.map(encodeString).joined(separator: ",") + "]"
        case .object(let fields):
            let sorted = fields.sorted { $0.key < $1.key }
            let body = sorted.map { "\(quote($0.key)):\(encodeString($0.value))" }.joined(separator: ",")
            return "{\(body)}"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00..<0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    struct Parser {
        let text: String
        let path: String
        var index: String.Index

        init(text: String, path: String) {
            self.text = text
            self.path = path
            index = text.startIndex
        }

        var isAtEnd: Bool { index == text.endIndex }

        mutating func parseValue() throws -> JSONValue {
            skipSpace()
            guard let character = peek() else { throw invalid() }
            switch character {
            case "{": return .object(try parseObject())
            case "[": return .array(try parseArray())
            case "\"": return .string(try parseString())
            case "t": return .bool(try consumeLiteral("true", true))
            case "f": return .bool(try consumeLiteral("false", false))
            case "n":
                _ = try consumeLiteral("null", true)
                return .null
            default:
                return .int(try parseInt())
            }
        }

        mutating func skipSpace() {
            while let character = peek(), character == " " || character == "\n" || character == "\r" || character == "\t" {
                index = text.index(after: index)
            }
        }

        private mutating func parseObject() throws -> [String: JSONValue] {
            _ = try expect("{")
            skipSpace()
            var fields: [String: JSONValue] = [:]
            if peek() == "}" {
                index = text.index(after: index)
                return fields
            }
            while true {
                skipSpace()
                let key = try parseString()
                if fields[key] != nil { throw invalid() }
                skipSpace()
                _ = try expect(":")
                let value = try parseValue()
                fields[key] = value
                skipSpace()
                if peek() == "," {
                    index = text.index(after: index)
                    continue
                }
                _ = try expect("}")
                return fields
            }
        }

        private mutating func parseArray() throws -> [JSONValue] {
            _ = try expect("[")
            skipSpace()
            var items: [JSONValue] = []
            if peek() == "]" {
                index = text.index(after: index)
                return items
            }
            while true {
                items.append(try parseValue())
                skipSpace()
                if peek() == "," {
                    index = text.index(after: index)
                    continue
                }
                _ = try expect("]")
                return items
            }
        }

        private mutating func parseString() throws -> String {
            _ = try expect("\"")
            var out = ""
            while let character = peek() {
                if character == "\"" {
                    index = text.index(after: index)
                    return out
                }
                if character == "\\" {
                    index = text.index(after: index)
                    guard let escaped = peek() else { throw invalid() }
                    index = text.index(after: index)
                    switch escaped {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u": out.append(try parseUnicodeEscape())
                    default: throw invalid()
                    }
                    continue
                }
                if character.unicodeScalars.contains(where: { $0.value < 0x20 }) { throw invalid() }
                out.append(character)
                index = text.index(after: index)
            }
            throw invalid()
        }

        private mutating func parseUnicodeEscape() throws -> String {
            let unit = try hex4()
            if (0xD800...0xDBFF).contains(unit) {
                guard peek() == "\\" else { throw invalid() }
                let mark = index
                index = text.index(after: index)
                guard peek() == "u" else { index = mark; throw invalid() }
                index = text.index(after: index)
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw invalid() }
                let scalar = 0x10000 + ((Int(unit) - 0xD800) << 10) + (Int(low) - 0xDC00)
                guard let unicode = UnicodeScalar(scalar) else { throw invalid() }
                return String(unicode)
            }
            if (0xDC00...0xDFFF).contains(unit) { throw invalid() }
            guard let unicode = UnicodeScalar(unit) else { throw invalid() }
            return String(unicode)
        }

        private mutating func hex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let character = peek() else { throw invalid() }
                index = text.index(after: index)
                guard let digit = character.hexDigitValue else { throw invalid() }
                value = (value << 4) | UInt32(digit)
            }
            return value
        }

        private mutating func parseInt() throws -> Int64 {
            let start = index
            if peek() == "-" { index = text.index(after: index) }
            guard let first = peek(), first.isNumber else { throw invalid() }
            if first == "0" {
                index = text.index(after: index)
                if let next = peek(), next.isNumber { throw invalid() }
            } else {
                while let next = peek(), next.isNumber { index = text.index(after: index) }
            }
            if let next = peek(), next == "." || next == "e" || next == "E" { throw invalid() }
            let token = String(text[start..<index])
            guard let number = Int64(token) else { throw invalid() }
            return number
        }

        private mutating func consumeLiteral<T>(_ literal: String, _ value: T) throws -> T {
            guard text[index...].hasPrefix(literal) else { throw invalid() }
            index = text.index(index, offsetBy: literal.count)
            return value
        }

        private mutating func expect(_ character: Character) throws -> Character {
            guard peek() == character else { throw invalid() }
            index = text.index(after: index)
            return character
        }

        private func peek() -> Character? { isAtEnd ? nil : text[index] }

        private func invalid() -> ContractError {
            ContractError(path: path, message: "Invalid JSON.")
        }
    }
}

enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case bool(Bool)
    case null

    var object: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var int: Int64? {
        if case .int(let number) = self { return number }
        return nil
    }
}

public struct ContractError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let message: String
    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
    public var description: String { "\(path): \(message)" }
}
