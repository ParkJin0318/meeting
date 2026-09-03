import SwiftUI
import MinimalUI

private struct MeetingScreenActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    public var meetingScreenActive: Bool {
        get { self[MeetingScreenActiveKey.self] }
        set { self[MeetingScreenActiveKey.self] = newValue }
    }
}

@MainActor
enum MNDateFormatShim {
    static func dayTime(_ date: Date) -> String { MNDateFormat.dayTime(date) }
}
