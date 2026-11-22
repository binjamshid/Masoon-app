/// Minimal deterministic JSON parser.
///
/// The engine never uses Foundation's JSON machinery: numbers are kept as their
/// raw decimal text so no binary floating point can influence emitted values
/// (ENGINE_PARITY §1). Object key order is irrelevant for our inputs
/// (`input.json` is canonical JSON with sorted keys); we store a dictionary.

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The raw numeric token exactly as it appeared in the document.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// PC-6: explicit JSON `null`, distinguished from "key absent" (callers
    /// hold the raw `JSONValue?` from a subscript and check this before
    /// falling through to `objectValue`/etc., which are all `nil` for `.null`
    /// too — so "absent" and "present-but-null" stay distinguishable).
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    /// Integral value if the token is a plain integer (no fraction/exponent).
    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }
    public var decimalValue: DecimalValue? {
        switch self {
        case .number(let n): return DecimalValue(string: n)
        case .string(let s): return DecimalValue(string: s)
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

public enum JSONParseError: Error, CustomStringConvertible {
    case malformed(String)
    public var description: String {
        if case .malformed(let m) = self { return "JSON parse error: \(m)" }
        return "JSON parse error"
    }
}

public enum JSONParser {
    public static func parse(_ text: String) throws -> JSONValue {
        var scanner = Scanner(Array(text.unicodeScalars))
        let value = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw JSONParseError.malformed("trailing content") }
        return value
    }

    public static func parse(bytes: [UInt8]) throws -> JSONValue {
        // Strict UTF-8 decode without Foundation.
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error: throw JSONParseError.malformed("input is not UTF-8")
            }
        }
        return try parse(String(scalars))
    }

    private struct Scanner {
        let chars: [Unicode.Scalar]
        var pos = 0

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        var isAtEnd: Bool { pos >= chars.count }

        mutating func skipWhitespace() {
            while pos < chars.count {
                let c = chars[pos]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { pos += 1 } else { break }
            }
        }

        mutating func peek() throws -> Unicode.Scalar {
            guard pos < chars.count else { throw JSONParseError.malformed("unexpected end of input") }
            return chars[pos]
        }

        mutating func expect(_ s: Unicode.Scalar) throws {
            guard try peek() == s else { throw JSONParseError.malformed("expected '\(s)' at offset \(pos)") }
            pos += 1
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            switch try peek() {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try parseLiteral("true"); return .bool(true)
            case "f": try parseLiteral("false"); return .bool(false)
            case "n": try parseLiteral("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func parseLiteral(_ lit: String) throws {
            for s in lit.unicodeScalars {
                guard pos < chars.count, chars[pos] == s else {
                    throw JSONParseError.malformed("invalid literal at offset \(pos)")
                }
                pos += 1
            }
        }

        mutating func parseObject() throws -> JSONValue {
            try expect("{")
            var dict: [String: JSONValue] = [:]
            skipWhitespace()
            if try peek() == "}" { pos += 1; return .object(dict) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                let value = try parseValue()
                dict[key] = value
                skipWhitespace()
                let c = try peek()
                if c == "," { pos += 1; continue }
                if c == "}" { pos += 1; break }
                throw JSONParseError.malformed("expected ',' or '}' at offset \(pos)")
            }
            return .object(dict)
        }

        mutating func parseArray() throws -> JSONValue {
            try expect("[")
            var items: [JSONValue] = []
            skipWhitespace()
            if try peek() == "]" { pos += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                let c = try peek()
                if c == "," { pos += 1; continue }
                if c == "]" { pos += 1; break }
                throw JSONParseError.malformed("expected ',' or ']' at offset \(pos)")
            }
            return .array(items)
        }

        mutating func parseString() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while true {
                guard pos < chars.count else { throw JSONParseError.malformed("unterminated string") }
                let c = chars[pos]
                pos += 1
                if c == "\"" { break }
                if c == "\\" {
                    guard pos < chars.count else { throw JSONParseError.malformed("unterminated escape") }
                    let e = chars[pos]
                    pos += 1
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        let unit = try parseHex4()
                        if unit >= 0xD800 && unit <= 0xDBFF {
                            // Surrogate pair.
                            guard pos + 1 < chars.count, chars[pos] == "\\", chars[pos + 1] == "u" else {
                                throw JSONParseError.malformed("unpaired surrogate")
                            }
                            pos += 2
                            let low = try parseHex4()
                            guard low >= 0xDC00 && low <= 0xDFFF else {
                                throw JSONParseError.malformed("invalid low surrogate")
                            }
                            let cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            guard let scalar = Unicode.Scalar(cp) else {
                                throw JSONParseError.malformed("invalid code point")
                            }
                            out.append(scalar)
                        } else {
                            guard let scalar = Unicode.Scalar(unit) else {
                                throw JSONParseError.malformed("invalid code point")
                            }
                            out.append(scalar)
                        }
                    default:
                        throw JSONParseError.malformed("invalid escape '\\\(e)'")
                    }
                } else {
                    out.append(c)
                }
            }
            return String(out)
        }

        mutating func parseHex4() throws -> Int {
            var v = 0
            for _ in 0..<4 {
                guard pos < chars.count, let d = chars[pos].hexDigitValue else {
                    throw JSONParseError.malformed("invalid \\u escape")
                }
                v = v * 16 + d
                pos += 1
            }
            return v
        }

        mutating func parseNumber() throws -> String {
            let start = pos
            if pos < chars.count, chars[pos] == "-" { pos += 1 }
            var sawDigit = false
            while pos < chars.count, chars[pos].isASCIIDigit { pos += 1; sawDigit = true }
            guard sawDigit else { throw JSONParseError.malformed("invalid number at offset \(start)") }
            if pos < chars.count, chars[pos] == "." {
                pos += 1
                var sawFrac = false
                while pos < chars.count, chars[pos].isASCIIDigit { pos += 1; sawFrac = true }
                guard sawFrac else { throw JSONParseError.malformed("invalid number fraction") }
            }
            if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
                pos += 1
                if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
                var sawExp = false
                while pos < chars.count, chars[pos].isASCIIDigit { pos += 1; sawExp = true }
                guard sawExp else { throw JSONParseError.malformed("invalid number exponent") }
            }
            return String(String.UnicodeScalarView(chars[start..<pos]))
        }
    }
}

private extension Unicode.Scalar {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - Unicode.Scalar("0").value)
        case "a"..."f": return Int(value - Unicode.Scalar("a").value + 10)
        case "A"..."F": return Int(value - Unicode.Scalar("A").value + 10)
        default: return nil
        }
    }
}
