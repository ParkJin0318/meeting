import Foundation

public enum MeetingList {
    public struct Section: Sendable, Identifiable {
        public let title: String
        public let meetings: [Meeting]
        public var id: String { title }
    }

    public static func filter(_ meetings: [Meeting], query: String) -> [Meeting] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title.localizedStandardContains(trimmed)
                || meeting.summary.localizedStandardContains(trimmed)
                || meeting.transcript.localizedStandardContains(trimmed)
        }
    }

    public static func sections(_ meetings: [Meeting],
                                now: Date = Date(),
                                calendar: Calendar = .current) -> [Section] {
        var buckets: [(title: String, meetings: [Meeting])] = []
        for meeting in meetings {
            let title = bucketTitle(for: meeting.scheduledAt, now: now, calendar: calendar)
            if buckets.last?.title == title {
                buckets[buckets.count - 1].meetings.append(meeting)
            } else {
                buckets.append((title, [meeting]))
            }
        }
        return buckets.map { Section(title: $0.title, meetings: $0.meetings) }
    }

    public enum Row: Sendable, Identifiable {
        case header(String)
        case meeting(Meeting)

        public var id: String {
            switch self {
            case let .header(title): "header-\(title)"
            case let .meeting(meeting): meeting.id
            }
        }
    }

    public static func rows(_ meetings: [Meeting],
                            now: Date = Date(),
                            calendar: Calendar = .current) -> [Row] {
        sections(meetings, now: now, calendar: calendar).flatMap { section in
            [Row.header(section.title)] + section.meetings.map(Row.meeting)
        }
    }

    private static func bucketTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "어제" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "이번 주"
        }
        return "이전"
    }
}

public extension Meeting {
    var summaryPreview: String? {
        for line in summary.components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            while let first = trimmed.first, "-*>".contains(first) {
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
