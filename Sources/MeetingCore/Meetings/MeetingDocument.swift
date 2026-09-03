import Foundation

public enum MeetingDocument {
    public static func transcriptText(_ meeting: Meeting) -> String {
        TranscriptMerger.plainText(meeting.displaySegments, names: meeting.speakerNames)
    }

    public static func markdown(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", ""]
        lines.append("- 일시: \(timestamp(meeting.startedAt ?? meeting.scheduledAt))")
        if let duration = durationText(meeting) {
            lines.append("- 길이: \(duration)")
        }
        let speakers = meeting.speakerLabels.map { meeting.displayName(for: $0) }
        if !speakers.isEmpty {
            lines.append("- 화자: \(speakers.joined(separator: ", "))")
        }
        if let note = meeting.diarizationNote {
            lines.append("- 화자 구분: \(note)")
        }
        if let coverage = meeting.coverage, let note = coverage.note {
            lines.append("- 전사 누락: \(note)")
            for gap in coverage.gaps {
                lines.append("  - \(gap.label)")
            }
        }
        lines.append("")

        if !meeting.summary.isEmpty {
            lines.append(contentsOf: ["## 요약", "", meeting.summary, ""])
        }
        let transcript = transcriptText(meeting)
        if !transcript.isEmpty {
            lines.append(contentsOf: ["## 전사", "", transcript, ""])
        }
        return lines.joined(separator: "\n")
    }

    public static func slug(_ meeting: Meeting) -> String {
        let date = dateStamp(meeting.startedAt ?? meeting.scheduledAt)
        let title = meeting.title
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .split(separator: " ")
            .joined(separator: "-")
        return title.isEmpty ? date : "\(date)-\(title)"
    }

    public static func linkTimecodes(in markdown: String) -> String {
        let pattern = #"\[((?:\d{1,2}:)?\d{1,2}:\d{2})\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let text = markdown as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            guard let seconds = parseTimecode(text.substring(with: match.range(at: 1))) else {
                continue
            }
            result += text.substring(with: NSRange(location: cursor,
                                                   length: match.range.location - cursor))
            let label = text.substring(with: match.range(at: 1))
            result += "[\(label)](\(timeLinkScheme):\(Int(seconds)))"
            cursor = match.range.location + match.range.length
        }
        result += text.substring(from: cursor)
        return result
    }

    public static let timeLinkScheme = "meeting-time"

    public static func seconds(fromLink url: URL) -> TimeInterval? {
        guard url.scheme == timeLinkScheme,
              let value = TimeInterval(url.absoluteString.dropFirst(timeLinkScheme.count + 1))
        else { return nil }
        return value
    }

    static func parseTimecode(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              let numbers = try? parts.map({ part -> Int in
                  guard let value = Int(part) else { throw CocoaError(.formatting) }
                  return value
              }) else { return nil }
        return parts.count == 2
            ? TimeInterval(numbers[0] * 60 + numbers[1])
            : TimeInterval(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }

    public static func durationText(_ meeting: Meeting) -> String? {
        guard let start = meeting.startedAt, let end = meeting.endedAt else { return nil }
        // 일시 중지 구간은 파일에 없으므로 뺀다 — 전사의 마지막 타임코드와 맞는 값이다.
        let seconds = Int(max(0, end.timeIntervalSince(start) - meeting.pausedSeconds))
        let minutes = seconds / 60
        return minutes >= 60
            ? "\(minutes / 60)시간 \(minutes % 60)분"
            : "\(minutes)분"
    }

    static func timestamp(_ date: Date) -> String {
        formatter(with: "yyyy-MM-dd HH:mm").string(from: date)
    }

    static func dateStamp(_ date: Date) -> String {
        formatter(with: "yyyy-MM-dd").string(from: date)
    }

    private static func formatter(with format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
