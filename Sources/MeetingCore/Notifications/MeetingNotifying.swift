import Foundation

public protocol MeetingNotifying: Sendable {
    func notice(message: String) async
}

public struct SilentMeetingNotifier: MeetingNotifying {
    public init() {}
    public func notice(message: String) async {}
}
