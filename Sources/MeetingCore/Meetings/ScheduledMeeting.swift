import Foundation

/// 호스트가 일정에서 골라 넘기는 "지금 시작하는 회의". 언제 띄울지는 호스트가 판정하고
/// 세션은 보관·무시 기록만 한다 — 같은 회의를 [x] 뒤에 다시 띄우지 않으려고 `id`는 회차마다 달라야 한다.
public struct ScheduledMeeting: Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
