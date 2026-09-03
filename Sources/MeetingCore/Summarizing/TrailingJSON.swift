import Foundation

public enum TrailingJSON {
    public static func extract(from text: String,
                               requiredKey: String = "summary") -> [String: Any]? {
        let bytes = Array(text.utf8)
        guard let closing = bytes.lastIndex(where: { !isASCIIWhitespace($0) }),
              bytes[closing] == UInt8(ascii: "}"),
              let opening = matchingBraceStart(in: bytes, closingAt: closing),
              let object = try? JSONSerialization.jsonObject(
                  with: Data(bytes[opening...closing])) as? [String: Any],
              object[requiredKey] != nil else { return nil }
        return object
    }

    private static func matchingBraceStart(in bytes: [UInt8], closingAt closing: Int) -> Int? {
        let quote = UInt8(ascii: "\""), open = UInt8(ascii: "{"), close = UInt8(ascii: "}")
        var depth = 0
        var inString = false
        for index in stride(from: closing, through: 0, by: -1) {
            let byte = bytes[index]
            if byte == quote, !isEscaped(bytes, at: index) {
                inString.toggle()
            } else if !inString {
                if byte == close {
                    depth += 1
                } else if byte == open {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
        }
        return nil
    }

    private static func isEscaped(_ bytes: [UInt8], at index: Int) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0, bytes[cursor] == UInt8(ascii: "\\") {
            backslashes += 1
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
