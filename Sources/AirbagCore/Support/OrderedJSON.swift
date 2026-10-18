import Foundation

/// JSON value that keeps object key order and number spelling, so editing a user's config file changes only
/// what we touch.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        get { if case .object(let kv) = self { return kv.first(where: { $0.0 == key })?.1 }; return nil }
        set {
            guard case .object(var kv) = self else { return }
            if let i = kv.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { kv[i].1 = v } else { kv.remove(at: i) }
            } else if let v = newValue { kv.append((key, v)) }
            self = .object(kv)
        }
    }

    public var arrayValue: [OrderedJSON]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var isObject: Bool { if case .object = self { return true }; return false }

    /// Builds a value from Foundation JSON objects (key order of dictionaries is not defined: pass arrays of pairs
    /// through `.object` directly when order matters).
    public static func from(_ any: Any) -> OrderedJSON {
        switch any {
        case let d as [String: Any]: return .object(d.keys.sorted().map { ($0, from(d[$0]!)) })
        case let a as [Any]: return .array(a.map(from))
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.stringValue)
        default: return .null
        }
    }

    // MARK: parsing

    public struct ParseError: Error, CustomStringConvertible { public let offset: Int; public let message: String
        public var description: String { "JSON parse error at byte \(offset): \(message)" } }

    public static func parse(_ text: String) throws -> OrderedJSON {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i, message: "trailing characters") }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        mutating func skipWS() {
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1; continue }
                // Tolerate // and /* */ comments (some users keep them in settings files).
                if c == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2F { while i < bytes.count && bytes[i] != 0x0A { i += 1 }; continue }
                if c == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2A {
                    i += 2
                    while i + 1 < bytes.count && !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                    i += 2; continue
                }
                break
            }
        }
        mutating func value() throws -> OrderedJSON {
            guard i < bytes.count else { throw ParseError(offset: i, message: "unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }
        mutating func literal(_ s: String) throws {
            let b = Array(s.utf8)
            guard i + b.count <= bytes.count, Array(bytes[i..<(i + b.count)]) == b else { throw ParseError(offset: i, message: "invalid literal") }
            i += b.count
        }
        mutating func number() throws -> OrderedJSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start else { throw ParseError(offset: i, message: "unexpected character") }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }
        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard i + 4 < bytes.count, let v = UInt32(String(decoding: bytes[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else {
                            throw ParseError(offset: i, message: "bad \\u escape")
                        }
                        i += 4
                        var scalar = v
                        if (0xD800...0xDBFF).contains(v), i + 6 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u"),
                           let lo = UInt32(String(decoding: bytes[(i + 3)...(i + 6)], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(lo) {
                            scalar = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                            i += 6
                        }
                        out.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "?").utf8))
                    default: out.append(e)
                    }
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
            }
            throw ParseError(offset: i, message: "unterminated string")
        }
        mutating func array() throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw ParseError(offset: i, message: "unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; skipWS(); if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw ParseError(offset: i, message: "expected , or ]")
            }
        }
        mutating func object() throws -> OrderedJSON {
            i += 1
            var kv: [(String, OrderedJSON)] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError(offset: i, message: "expected key") }
                let k = try string()
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError(offset: i, message: "expected :") }
                i += 1
                skipWS()
                kv.append((k, try value()))
                skipWS()
                guard i < bytes.count else { throw ParseError(offset: i, message: "unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; skipWS(); if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                throw ParseError(offset: i, message: "expected , or }")
            }
        }
    }

    // MARK: serialisation (2-space indent, like Claude Code and most editors)

    public func serialized(indent: Int = 2) -> String {
        var out = ""
        write(&out, level: 0, indent: indent)
        return out + "\n"
    }

    func write(_ out: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let closePad = String(repeating: " ", count: level * indent)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += OrderedJSON.quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.write(&out, level: level + 1, indent: indent)
                out += i < a.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "]"
        case .object(let kv):
            if kv.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, (k, v)) in kv.enumerated() {
                out += pad + OrderedJSON.quote(k) + ": "
                v.write(&out, level: level + 1, indent: indent)
                out += i < kv.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
