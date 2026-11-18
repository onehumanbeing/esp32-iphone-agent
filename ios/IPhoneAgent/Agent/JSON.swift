import Foundation

/// A JSON value. Agent steps are ordered objects, like the Python dicts they replace, so the history
/// sent to the model reads exactly as before (`json.dumps` key order and spacing).
enum JValue: Equatable {
    case int(Int), num(Double), str(String), bool(Bool), arr([JValue]), obj(JObject), null

    var int: Int? { if case .int(let v) = self { return v }; return nil }
    var str: String? { if case .str(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var arr: [JValue]? { if case .arr(let v) = self { return v }; return nil }
    var double: Double? {
        switch self { case .int(let v): return Double(v); case .num(let v): return v; default: return nil }
    }
}

/// An insertion-ordered JSON object; equality ignores order, like Python dicts.
struct JObject: Equatable, ExpressibleByDictionaryLiteral {
    private(set) var pairs: [(String, JValue)] = []

    init(_ pairs: [(String, JValue)] = []) { pairs.forEach { self[$0.0] = $0.1 } }
    init(dictionaryLiteral elements: (String, JValue)...) { self.init(elements) }

    var keys: [String] { pairs.map(\.0) }

    subscript(key: String) -> JValue? {
        get { pairs.first { $0.0 == key }?.1 }
        set {
            let i = pairs.firstIndex { $0.0 == key }
            switch (i, newValue) {
            case let (i?, v?): pairs[i].1 = v
            case let (nil, v?): pairs.append((key, v))
            case let (i?, nil): pairs.remove(at: i)
            case (nil, nil): break
            }
        }
    }

    /// `{**a, **b}`: b's keys win, a's order first.
    func merging(_ other: JObject) -> JObject {
        var out = self
        other.pairs.forEach { out[$0.0] = $0.1 }
        return out
    }

    func without(_ hidden: Set<String>) -> JObject { JObject(pairs.filter { !hidden.contains($0.0) }) }

    static func == (a: JObject, b: JObject) -> Bool {
        a.pairs.count == b.pairs.count && a.pairs.allSatisfy { b[$0.0] == $0.1 }
    }
}

/// Python's `json.dumps` output format (", " and ": " separators).
enum PyJSON {
    static func dumps(_ v: JValue, ascii: Bool = true) -> String {
        switch v {
        case .int(let i): return String(i)
        case .num(let d): return d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .str(let s): return quote(s, ascii: ascii)
        case .arr(let a): return "[" + a.map { dumps($0, ascii: ascii) }.joined(separator: ", ") + "]"
        case .obj(let o): return dumps(o, ascii: ascii)
        }
    }

    static func dumps(_ o: JObject, ascii: Bool = true) -> String {
        "{" + o.pairs.map { quote($0.0, ascii: ascii) + ": " + dumps($0.1, ascii: ascii) }.joined(separator: ", ") + "}"
    }

    private static func quote(_ s: String, ascii: Bool) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || (ascii && u.value > 0x7e) {
                    for unit in String(u).utf16 { out += String(format: "\\u%04x", unit) }
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// Convert a Foundation JSON object (from JSONSerialization) into a JValue.
    static func from(_ any: Any?) -> JValue {
        switch any {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return .bool(n.boolValue)
        case let n as NSNumber: return n.doubleValue == n.doubleValue.rounded() && !"\(n)".contains(".")
            ? .int(n.intValue) : .num(n.doubleValue)
        case let s as String: return .str(s)
        case let a as [Any]: return .arr(a.map(from))
        case let d as [String: Any]: return .obj(JObject(d.keys.sorted().map { ($0, from(d[$0])) }))
        default: return .null
        }
    }
}
