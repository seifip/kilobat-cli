import Foundation

/// JSON that keeps its keys in the order they were written and its numbers as written, so a file another app owns
/// (Claude Code's settings, Codex's hooks) comes back the same apart from what Kilobat changed. JSONSerialization
/// would reorder every key in someone's settings file.
public indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal as written: 1, 2.50, 1e3.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON
        public init(_ key: String, _ value: OrderedJSON) { self.key = key; self.value = value }
    }

    public struct ParseError: Error, Equatable, Sendable { public let offset: Int }

    // MARK: Access

    public subscript(key: String) -> OrderedJSON? {
        get { if case .object(let members) = self { return members.first { $0.key == key }?.value }; return nil }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var array: [OrderedJSON]? { if case .array(let value) = self { return value }; return nil }
    public var members: [Member]? { if case .object(let value) = self { return value }; return nil }
    public var isObject: Bool { members != nil }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 256, index < bytes.count else { throw ParseError(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw ParseError(offset: index) }
            index += expected.count
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let allowed = Set("0123456789+-.eE".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty, text != "-", Double(text) != nil else { throw ParseError(offset: start) }
            return .number(text)
        }

        mutating func object(depth: Int) throws -> OrderedJSON {
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object([]) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError(offset: index) }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError(offset: index) }
                index += 1
                skipSpace()
                members.append(Member(key, try value(depth: depth + 1)))
                skipSpace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw ParseError(offset: index)
            }
        }

        mutating func array(depth: Int) throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array([]) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError(offset: index)
            }
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = [UInt8]()
            func flush() { if !run.isEmpty { scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars); run.removeAll() } }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { index += 1; flush(); return String(scalars) }
                guard byte >= 0x20 else { throw ParseError(offset: index) }
                if byte != UInt8(ascii: "\\") { run.append(byte); index += 1; continue }
                flush()
                index += 1
                guard index < bytes.count else { throw ParseError(offset: index) }
                let escape = bytes[index]; index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let mark = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) } else { index = mark }
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw ParseError(offset: index - 1)
                }
            }
            throw ParseError(offset: index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { throw ParseError(offset: index) }
            index += 4
            return value
        }
    }

    // MARK: Writing

    /// Two-space indentation, as Claude Code, Codex and most editors write these files, with a final newline.
    public func serialized() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out + "\n"
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1), close = String(repeating: "  ", count: indent)
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let text): out += text
        case .string(let value): out += Self.quoted(value)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (offset, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += offset == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (offset, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        }
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
