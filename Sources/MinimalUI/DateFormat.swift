import Foundation

@MainActor
public enum MNDateFormat {
    public static func dayTime(_ date: Date) -> String {
        dayTimeFormatter.string(from: date)
    }

    public static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    public static func fullDay(_ date: Date) -> String {
        fullDayFormatter.string(from: date)
    }

    public static func weekdayShort(_ date: Date) -> String {
        weekdayFormatter.string(from: date)
    }

    public static func monthDay(_ date: Date) -> String {
        monthDayFormatter.string(from: date)
    }

    public static func dayNumber(_ date: Date) -> String {
        dayNumberFormatter.string(from: date)
    }

    public static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    public static func timer(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d",
                          seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static let dayTimeFormatter = korean { $0.dateFormat = "M월 d일 HH:mm" }
    private static let timeFormatter = korean { $0.dateFormat = "HH:mm" }
    private static let fullDayFormatter = korean { $0.dateFormat = "M월 d일 EEEE" }
    private static let weekdayFormatter = korean { $0.dateFormat = "EEEEE" }
    private static let monthDayFormatter = korean { $0.dateFormat = "M월 d일" }
    private static let dayNumberFormatter = korean { $0.dateFormat = "d" }
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter
    }()

    private static func korean(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        configure(formatter)
        return formatter
    }
}
