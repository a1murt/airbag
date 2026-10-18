import Foundation

/// Loosely-typed accessors for agent payloads, which vary by agent and version.
public struct JSONObject: @unchecked Sendable {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }

    public static func parse(_ data: Data) -> JSONObject? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { return nil }
        return JSONObject(obj)
    }

    public subscript(_ key: String) -> Any? { raw[key] }
    public func string(_ key: String) -> String? {
        switch raw[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    public func bool(_ key: String) -> Bool? {
        switch raw[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased()) ? true : (["false", "0", "no"].contains(s.lowercased()) ? false : nil)
        default: return nil
        }
    }
    public func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue ?? string(key).flatMap { Int($0) } }
    public func object(_ key: String) -> JSONObject? {
        if let o = raw[key] as? [String: Any] { return JSONObject(o) }
        // Some agents (Copilot) send nested objects as JSON strings.
        if let s = raw[key] as? String, let d = s.data(using: .utf8), let o = JSONObject.parse(d) { return o }
        return nil
    }
    public func array(_ key: String) -> [Any]? { raw[key] as? [Any] }
    public func strings(_ key: String) -> [String] { (raw[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
}

public enum JSONOutput {
    /// Serialises a JSON-compatible value with sorted keys (stable output for tests and agents).
    public static func string(_ value: Any, pretty: Bool = false) -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: opts.union(.fragmentsAllowed))
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
