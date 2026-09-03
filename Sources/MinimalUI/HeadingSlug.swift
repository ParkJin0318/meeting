import Foundation

public enum HeadingSlug {
    public static func slug(_ heading: String) -> String {
        var out = ""
        for ch in heading.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            } else if ch.isWhitespace {
                out.append("-")
            }
        }
        return out
    }

    public static func slugs(forHeadings headings: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return headings.map { heading in
            let base = slug(heading)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return n == 0 ? base : "\(base)-\(n)"
        }
    }
}
