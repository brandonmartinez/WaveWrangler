import Foundation

/// Strict structural pre-check for canonical JSON: refuses duplicate object keys anywhere in the document.
///
/// Foundation's decoders silently keep one of the duplicated values, which would make fields such as
/// `revision` or `schemaVersion` ambiguous. Keys are compared after escape decoding, so `"a"` and `"\u0061"`
/// are the same key. Only well-formed JSON passes; anything else is reported as malformed too.
enum StrictJSON {
    enum Problem: Error, Equatable {
        case duplicateKey(String)
        case malformed(offset: Int)
    }

    static func validate(_ data: Data) throws(Problem) {
        var parser = Parser(bytes: [UInt8](data))
        try parser.skipWhitespace()
        try parser.value(depth: 0)
        try parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw .malformed(offset: parser.index) }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 512

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func skipWhitespace() throws(Problem) {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws(Problem) {
            guard depth < Self.maxDepth, index < bytes.count else { throw .malformed(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): try object(depth: depth + 1)
            case UInt8(ascii: "["): try array(depth: depth + 1)
            case UInt8(ascii: "\""): _ = try string()
            case UInt8(ascii: "t"): try literal("true")
            case UInt8(ascii: "f"): try literal("false")
            case UInt8(ascii: "n"): try literal("null")
            default: try number()
            }
        }

        mutating func object(depth: Int) throws(Problem) {
            index += 1
            var keys = Set<String>()
            try skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return }
            while true {
                try skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw .malformed(offset: index) }
                let key = try string()
                guard keys.insert(key).inserted else { throw .duplicateKey(key) }
                try skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw .malformed(offset: index) }
                index += 1
                try skipWhitespace()
                try value(depth: depth)
                try skipWhitespace()
                guard index < bytes.count else { throw .malformed(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return }
                throw .malformed(offset: index)
            }
        }

        mutating func array(depth: Int) throws(Problem) {
            index += 1
            try skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return }
            while true {
                try skipWhitespace()
                try value(depth: depth)
                try skipWhitespace()
                guard index < bytes.count else { throw .malformed(offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return }
                throw .malformed(offset: index)
            }
        }

        /// Parses a string literal and returns its decoded value.
        mutating func string() throws(Problem) -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() throws(Problem) {
                guard !raw.isEmpty else { return }
                guard let text = String(validating: raw, as: UTF8.self) else { throw .malformed(offset: index) }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll(keepingCapacity: true)
            }
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    try flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush()
                    index += 1
                    guard index < bytes.count else { throw .malformed(offset: index) }
                    switch bytes[index] {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var unit = try hex4()
                        if (0xD800...0xDBFF).contains(unit) {
                            guard index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\"), bytes[index + 2] == UInt8(ascii: "u")
                            else { throw .malformed(offset: index) }
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw .malformed(offset: index) }
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(unit) else { throw .malformed(offset: index) }
                        scalars.append(scalar)
                    default: throw .malformed(offset: index)
                    }
                    index += 1
                default:
                    guard byte >= 0x20 else { throw .malformed(offset: index) }
                    raw.append(byte)
                    index += 1
                }
            }
            throw .malformed(offset: index)
        }

        /// Reads 4 hex digits after `\u`; leaves `index` on the last digit.
        mutating func hex4() throws(Problem) -> UInt32 {
            guard index + 4 < bytes.count else { throw .malformed(offset: index) }
            var value: UInt32 = 0
            for offset in 1...4 {
                guard let digit = Character(UnicodeScalar(bytes[index + offset])).hexDigitValue else { throw .malformed(offset: index + offset) }
                value = value * 16 + UInt32(digit)
            }
            index += 4
            return value
        }

        mutating func literal(_ word: String) throws(Problem) {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index..<(index + utf8.count)]) == utf8 else { throw .malformed(offset: index) }
            index += utf8.count
        }

        mutating func number() throws(Problem) {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
                || [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"), UInt8(ascii: "-")].contains(bytes[index]) {
                index += 1
            }
            guard index > start, Double(String(decoding: bytes[start..<index], as: UTF8.self)) != nil else { throw .malformed(offset: start) }
        }
    }
}
